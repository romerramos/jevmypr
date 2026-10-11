class AddSourceAndIpDigestToJevRequests < ActiveRecord::Migration[8.1]
  def change
    # "web" for signed-in verdicts, "api" for diffs sent to the open API, so the API's share of the budget can be capped.
    add_column :jev_requests, :source, :string, null: false, default: "web"
    # A keyed hash of the caller's IP address for the API's daily cap, never the address itself. Forgotten after two days.
    add_column :jev_requests, :ip_digest, :string
    add_index :jev_requests, [ :ip_digest, :created_at ]
    add_index :jev_requests, [ :source, :sent_at ]
  end
end
