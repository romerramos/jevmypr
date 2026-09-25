import { Controller } from "@hotwired/stimulus"

const LIGHT = "triage"
const DARK = "triage-night"

// Switches between the light and dark triage themes and remembers the choice.
export default class extends Controller {
  connect() {
    if (!this.element.dataset.theme) {
      const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches
      this.element.dataset.theme = prefersDark ? DARK : LIGHT
    }
  }

  toggle() {
    const theme = this.element.dataset.theme === DARK ? LIGHT : DARK
    this.element.dataset.theme = theme
    try {
      localStorage.setItem("theme", theme)
    } catch (_) {}
  }
}
