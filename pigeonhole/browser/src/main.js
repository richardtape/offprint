// The script a page loads the first time a visitor touches its comment form (loader.js does the loading). It takes
// what the form holds, encrypts it in this browser to the site owner's public keys, and posts it to the site's own
// origin. Nothing is sent anywhere else, and nothing readable leaves the page.
import { Encrypter } from "age-encryption";
import { sha256 } from "@noble/hashes/sha2.js";
import { commentFields, envelope, padded, body, send } from "./transport.js";

export const SAYS = {
  sending: "Encrypting and sending your comment…",
  sent: "Thank you. Your comment was encrypted in your browser and sent. It will appear here once the site's owner has approved it.",
  failed: "Sorry, your comment could not be sent. What you wrote is still here: please try again in a moment.",
  empty: "Please write a comment first.",
  missing: "Please fill in your name and your email address, and check that the address is right.",
  long: "Sorry, that is too long to send. Please shorten it and try again.",
};

// Encrypts BYTES to every one of RECIPIENTS (age public keys): whoever holds any one of the private keys can open it.
export async function seal(bytes, recipients) {
  const encrypter = new Encrypter();
  for (const recipient of recipients) encrypter.addRecipient(recipient);
  return encrypter.encrypt(bytes);
}

// The form's own methods, called from their prototypes where there is one (a page): a field named "querySelector" or
// "append" stands in for the form's own property of that name, and must not stand in for these.
const inForm = (form, selector) =>
  typeof Element === "function" && form instanceof Element ? Element.prototype.querySelector.call(form, selector) : form.querySelector(selector);
const addTo = (form, element) =>
  typeof Element === "function" && form instanceof Element ? Element.prototype.append.call(form, element) : form.append(element);
const field = (form, name) => inForm(form, `[name="${name}"]`);

// The line under the form that says how it went: made once, and announced to a screen reader when it changes.
function note(form, page) {
  let p = inForm(form, ".offprint-pigeonhole-status");
  if (!p) {
    p = typeof Document === "function" && page instanceof Document ? Document.prototype.createElement.call(page, "p") : page.createElement("p");
    p.className = "offprint-pigeonhole-status";
    p.setAttribute("role", "status");
    addTo(form, p);
  }
  return p;
}

// Whether a field the site asks for is filled in, and filled in as its kind asks (an email address that is one).
// WordPress marks such a field "required"; a theme's form may turn the browser's own checking off, so it is done here.
// What the visitor is told is sent must be something WordPress will take.
function fieldOk(input) {
  if (!input) return true;
  const asked = input.required === true || (input.getAttribute && input.getAttribute("aria-required") === "true");
  if (asked && String(input.value ?? "").trim() === "") return false;
  return typeof input.checkValidity === "function" ? input.checkValidity() : true;
}

// Sends what FORM holds. CONFIG is the page's own ({path, recipients, bits}); STARTED is when the visitor first
// touched the form (milliseconds). One at a time: a second press while one is being sent does nothing.
let sending = false;
export async function submit(form, config, started) {
  if (sending) return;
  const page = typeof document === "object" ? document : form.ownerDocument;
  const says = note(form, page);
  const values = {};
  const inputs = {};
  for (const name of ["comment_post_ID", "comment_parent", "author", "email", "url", "comment", "offprint_hp"]) {
    inputs[name] = field(form, name);
    values[name] = inputs[name] ? inputs[name].value : "";
  }
  const { fields, problem } = commentFields(values, (Date.now() - started) / 1000);
  if (problem) { says.textContent = problem === "empty" ? SAYS.empty : SAYS.long; return; }
  if (!fieldOk(inputs.author) || !fieldOk(inputs.email)) { says.textContent = SAYS.missing; return; }
  const plain = padded(envelope("comment", fields, { page: page.location.pathname }));
  if (!plain) { says.textContent = SAYS.long; return; }

  sending = true;
  const button = inForm(form, '[type="submit"]');
  if (button) button.disabled = true;
  says.textContent = SAYS.sending;
  try {
    const sealed = await seal(plain, config.recipients);
    // The path on the page's own origin, whatever a <base> element in the page says.
    const address = new URL(config.path, page.location.origin).href;
    if (!(await send(address, await body(sealed, config.bits, sha256)))) throw new Error("not taken");
    // Only the text goes: a name and an address are kept for a second comment.
    if (inputs.comment) inputs.comment.value = "";
    says.textContent = SAYS.sent;
  } catch {
    says.textContent = SAYS.failed;
  }
  if (button) button.disabled = false;
  sending = false;
}
