import { Controller } from "@hotwired/stimulus"

const LIGHT = "triage"
const DARK = "triage-night"
const BROWSER_UI_COLORS = { [LIGHT]: "#FBFCFD", [DARK]: "#121922" }

// Switches between the light and dark triage themes and remembers the choice.
export default class extends Controller {
  connect() {
    if (!this.element.dataset.theme) {
      const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches
      this.element.dataset.theme = prefersDark ? DARK : LIGHT
    }
    this.#syncBrowserColor()
  }

  toggle() {
    const theme = this.element.dataset.theme === DARK ? LIGHT : DARK
    this.element.dataset.theme = theme
    this.#syncBrowserColor()
    try {
      localStorage.setItem("theme", theme)
    } catch (_) {}
  }

  // Keep the browser/PWA title bar in step with the chosen theme, not just the OS setting.
  #syncBrowserColor() {
    const color = BROWSER_UI_COLORS[this.element.dataset.theme]
    document.querySelectorAll('meta[name="theme-color"]').forEach((meta) => meta.setAttribute("content", color))
  }
}
