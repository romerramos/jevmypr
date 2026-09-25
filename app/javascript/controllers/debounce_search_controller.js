import { Controller } from "@hotwired/stimulus"

// Submits the search form shortly after the user stops typing.
// A pending search is dropped when another form submits (e.g. "Ask Jev"): the search's
// URL-updating visit would otherwise cancel that submission.
export default class extends Controller {
  static values = { wait: { type: Number, default: 250 } }

  submit() {
    clearTimeout(this.timeout)
    this.timeout = setTimeout(() => this.element.requestSubmit(), this.waitValue)
  }

  cancel(event) {
    if (event.target !== this.element) clearTimeout(this.timeout)
  }

  disconnect() {
    clearTimeout(this.timeout)
  }
}
