import { Controller } from "@hotwired/stimulus"

// Keyboard-first repository and pull request picker.
//   "/"        focus the repository search
//   ↓ / ↑      move through the list in the current pane (from its search box too)
//   Enter      open the focused repository or ask Jev about the focused pull request
//
// On phones the panes stack, so only one shows at a time: picking a repository switches the
// panes to "pulls", and the back button returns to the repository list where the user left it.
const PHONE = window.matchMedia("(max-width: 47.99rem)")

export default class extends Controller {
  static targets = ["search", "panes", "loading"]

  focusSearch(event) {
    if (event.key !== "/" || event.metaKey || event.ctrlKey || event.altKey) return
    if (event.target.closest("input, textarea, select, [contenteditable]")) return

    event.preventDefault()
    this.searchTarget.focus()
    this.searchTarget.select()
  }

  navigate(event) {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return

    const pane = event.target.closest("[data-picker-pane]")
    if (!pane) return

    const items = [...pane.querySelectorAll("[data-picker-item]")]
    if (items.length === 0) return

    event.preventDefault()
    const index = items.indexOf(event.target.closest("[data-picker-item]"))

    if (index === -1) {
      if (event.key === "ArrowDown") items[0].focus()
    } else if (event.key === "ArrowDown") {
      items[Math.min(index + 1, items.length - 1)].focus()
    } else if (index === 0) {
      pane.querySelector("input[type=search]")?.focus()
    } else {
      items[index - 1].focus()
    }
  }

  // Keep the address bar pointing at the dashboard with the chosen repository, so reloads and back work.
  selectRepository(event) {
    const link = event.target.closest("[data-repo]")
    if (!link) return

    this.element.querySelectorAll("[data-repo][aria-current]").forEach((el) => el.removeAttribute("aria-current"))
    link.setAttribute("aria-current", "true")
    this.element.querySelectorAll("input[type=hidden][name=repo]").forEach((input) => (input.value = link.dataset.repo))

    this.#setRepoInUrl(link.dataset.repo)
    this.#showLoadingPullRequests()

    this.repositoryScroll = window.scrollY
    this.panesTarget.dataset.view = "pulls"
    if (PHONE.matches) this.panesTarget.scrollIntoView({ block: "start" })
  }

  showRepositories() {
    this.panesTarget.dataset.view = "repos"
    this.#setRepoInUrl(null)
    window.scrollTo({ top: this.repositoryScroll ?? this.panesTarget.offsetTop })
  }

  #showLoadingPullRequests() {
    const frame = this.element.querySelector("turbo-frame#pull_requests")
    if (frame && this.hasLoadingTarget) frame.replaceChildren(this.loadingTarget.content.cloneNode(true))
  }

  #setRepoInUrl(repo) {
    const url = new URL(window.location.href)
    repo ? url.searchParams.set("repo", repo) : url.searchParams.delete("repo")
    history.replaceState(history.state, "", url)
  }
}
