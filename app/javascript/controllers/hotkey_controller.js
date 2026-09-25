import { Controller } from "@hotwired/stimulus"

// Visits a URL when a key is pressed outside of form fields, e.g. Esc to go back to the picker.
export default class extends Controller {
  static values = { key: String, url: String }

  visit(event) {
    if (event.key !== this.keyValue) return
    if (event.target.closest("input, textarea, select, [contenteditable]")) return

    Turbo.visit(this.urlValue)
  }
}
