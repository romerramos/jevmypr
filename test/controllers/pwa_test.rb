require "test_helper"

class PwaTest < ActionDispatch::IntegrationTest
  test "pages are titled with the app name and link the manifest and icons" do
    get new_session_path

    assert_select "title", "Sign in – Jev my PR"
    assert_select "link[rel=manifest][href=?]", pwa_manifest_path(format: :json)
    assert_select "link[rel=icon][href='/icon.svg']"
    assert_select "link[rel=apple-touch-icon][href='/apple-touch-icon.png']"
    assert_select "meta[name=theme-color]", 2
    assert_select "footer", text: /Jev is almost free to run/ do
      assert_select "a[href='https://buymeacoffee.com/romerramos']", /Chip in for tokens/
    end
  end

  test "manifest describes an installable app with any and maskable icons" do
    get pwa_manifest_path(format: :json)

    manifest = response.parsed_body
    assert_equal "Jev my PR", manifest["name"]
    assert_equal "standalone", manifest["display"]
    assert_equal %w[any maskable], manifest["icons"].map { _1["purpose"] }.uniq
    manifest["icons"].each { |icon| assert Rails.public_path.join(icon["src"].delete_prefix("/")).exist?, "#{icon["src"]} is missing" }
  end

  test "service worker is served with an offline fallback" do
    get pwa_service_worker_path(format: :js)

    assert_response :success
    assert_includes response.body, "/offline.html"
    assert Rails.public_path.join("offline.html").exist?
  end
end
