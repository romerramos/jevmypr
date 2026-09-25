import { Controller } from "@hotwired/stimulus"

// Keyboard support and "you are here" for the repository/pull request picker.
// Navigation itself is plain links and forms handled by Turbo.
//   "/"        focus the repository search
//   ↓ / ↑      move through the list in the current pane (from its search box too)
//   Enter      open the focused repository or ask Jev about the focused pull request
export default class extends Controller {
  static targets = ["search"]

  connect() {
    this.markCurrent()
  }

  focusSearch(event) {
    if (event.key !== "/" || event.metaKey || event.ctrlKey || event.altKey) return
    if (event.target.closest("input, textarea, select, [contenteditable]")) return
    if (!this.hasSearchTarget || !this.searchTarget.checkVisibility()) return

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

  // The repository sidebar is kept across visits (data-turbo-permanent), so the server can't
  // re-render which repository is open; mark the link that matches the current page instead.
  markCurrent() {
    this.element.querySelectorAll("a[data-picker-item]").forEach((link) => {
      if (new URL(link.href).pathname === window.location.pathname) {
        link.setAttribute("aria-current", "page")
      } else {
        link.removeAttribute("aria-current")
      }
    })
  }
}
