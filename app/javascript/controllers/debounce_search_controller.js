import { Controller } from "@hotwired/stimulus"

// Submits the search form shortly after the user stops typing.
export default class extends Controller {
  static values = { wait: { type: Number, default: 250 } }

  submit() {
    clearTimeout(this.timeout)
    this.timeout = setTimeout(() => this.element.requestSubmit(), this.waitValue)
  }

  disconnect() {
    clearTimeout(this.timeout)
  }
}
