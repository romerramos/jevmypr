require "test_helper"

class PrAssessmentCreatorTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  FakeGithub = Struct.new(:pull_request) do
    def pull_request_files(*) = []
    def pull_request(*) = self[:pull_request]
  end

  setup do
    @repository = Repository.create!(github_id: 999_001, full_name: "acme/concurrency-sample")
    @requester = User.create!(github_uid: "concurrency-requester", login: "requester")
    @teammate = User.create!(github_uid: "concurrency-teammate", login: "teammate")
    @pull_request = DevelopmentPreview.pull_request("acme/web", 7)
    @entered = Queue.new
    @resume = Queue.new
    @jev = Object.new
    entered, resume = @entered, @resume
    @jev.define_singleton_method(:ask) do |**|
      entered << ActiveRecord::Base.connection.object_id
      raise "The test did not release the simulated network call" unless resume.pop(timeout: 10)

      Jev::Client::Response.new(model: "test", answers: {
        "needs_human_review" => { "choice" => "no", "probabilities" => { "no" => 0.9 }, "confidence" => 0.8 }
      }, usage: { "input_tokens" => 1234, "output_tokens" => 17 })
    end
  end

  teardown do
    @resume << true
    @worker&.join(10)
    @repository.pr_assessments.destroy_all
    JevRequest.where(repository: @repository).delete_all
    @repository.destroy!
    @requester.destroy! unless @requester.destroyed?
    @teammate.destroy!
  end

  test "a concurrent ordinary request coalesces and another connection can write while Jev waits" do
    start_request
    assert_not_equal ActiveRecord::Base.connection.object_id, @worker_connection

    @teammate.pinned_repositories.create!(full_name: @repository.full_name)
    assert @worker.alive?, "The simulated Jev call must still be waiting during the independent write"
    assert_raises(PrAssessmentCreator::InProgress) { creator(@teammate).call(@pull_request) }
    assert_equal 1, JevRequest.where(repository: @repository).count
    assert_equal [ 1, 0 ], [ JevAllowance.new(@requester).weekly_used, JevAllowance.new(@teammate).weekly_used ]

    @resume << true
    assert @worker.join(5), "The original request should finish after the network response"
    saved = @worker.value
    assert_equal "succeeded", saved.jev_request.state
    assert_equal @requester, saved.user
    assert_equal saved, creator(@teammate).call(@pull_request)
    assert_equal 1, @repository.pr_assessments.count
    assert_equal 1, JevRequest.where(repository: @repository).count
    assert_equal [ 1, 0 ], [ JevAllowance.new(@requester).weekly_used, JevAllowance.new(@teammate).weekly_used ]
  end

  test "deletion during a Jev call cannot resurrect requester attribution or erase its paid usage" do
    start_request
    @requester.destroy!
    assert @worker.alive?

    @resume << true
    assert @worker.join(5)
    saved = @worker.value
    assert_nil saved.user_id
    assert_nil saved.jev_request.user_id
    assert_equal @repository, saved.repository
    assert_equal [ 1234, 17 ], saved.jev_request.values_at(:input_tokens, :output_tokens)
    assert_equal 0, JevAllowance.new(@teammate).weekly_used
    assert_in_delta 0.000052542, JevAllowance.new(@teammate).monthly_spend_usd, 1e-12
  end

  private
    def creator(user)
      PrAssessmentCreator.new(user: user, repository: @repository, github: FakeGithub.new(@pull_request), jev: @jev)
    end

    def start_request
      @worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { creator(@requester).call(@pull_request) }
      end
      @worker.report_on_exception = false
      @worker_connection = @entered.pop(timeout: 5)
      assert @worker_connection, "The first request must reserve and reach the simulated Jev call"
    end
end
