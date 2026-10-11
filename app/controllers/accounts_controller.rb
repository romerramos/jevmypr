# Removes personal data and requester links. Repository snapshots and anonymous usage survive.
class AccountsController < ApplicationController
  def destroy
    user = Current.user
    terminate_session
    user.destroy!

    redirect_to new_session_path, status: :see_other,
      notice: "Your account, token, sessions, pins and private votes are deleted. Shared repository verdicts stay, " \
              "without a link to your account; private legacy snapshots are deleted. To also revoke this app's GitHub access, " \
              "go to GitHub → Settings → Applications → Authorized OAuth Apps."
  end
end
