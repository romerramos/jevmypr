# Lets people remove everything Jev my PR stores about them: their user record, encrypted GitHub
# token, sessions, verdicts, pinned repositories and too-big marks.
class AccountsController < ApplicationController
  def destroy
    user = Current.user
    terminate_session
    user.destroy!

    redirect_to new_session_path, status: :see_other,
      notice: "Your account, verdicts and pins are deleted. To also revoke this app's GitHub access, " \
              "go to GitHub → Settings → Applications → Authorized OAuth Apps."
  end
end
