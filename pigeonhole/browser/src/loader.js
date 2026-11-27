// The small script every page with a comment form loads. It does nothing until a visitor touches the form; then it
// loads the script that encrypts and sends (pigeonhole.js, beside this file), once. A reader who never comments pays
// for this file and no more. The page says where comments go and to whose keys, in a JSON block of its own.
//
// The form cannot post by itself (its method is "dialog", which a browser does nothing with outside a dialog), so a
// visitor for whom this script never ran sends nothing. The page is found with the document's own querySelector,
// called from its prototype: an element a post's author named "forms" or "querySelector" stands in for the
// document's own property of that name, and must not stand in for this.
const find = (selector) => Document.prototype.querySelector.call(document, selector);
const block = find('script#offprint-pigeonhole[type="application/json"]');
let config = null;
try { config = block ? JSON.parse(block.textContent) : null; } catch { config = null; }
const form = config && typeof config.path === "string" ? find("form[data-offprint-pigeonhole]") : null;

if (form) {
  const on = (type, handler) => EventTarget.prototype.addEventListener.call(form, type, handler);
  let started = 0;
  let script = null;
  const touch = () => {
    if (!started) started = Date.now();
    if (!script) script = import("./pigeonhole.js");
    return script;
  };
  on("focusin", touch);
  on("pointerdown", touch);
  on("submit", (event) => {
    event.preventDefault();
    touch().then(
      (module) => module.submit(form, config, started),
      () => {
        script = null;
        let says = Element.prototype.querySelector.call(form, ".offprint-pigeonhole-status");
        if (!says) {
          says = document.createElement("p");
          says.className = "offprint-pigeonhole-status";
          says.setAttribute("role", "status");
          Element.prototype.append.call(form, says);
        }
        says.textContent = "Sorry, your comment could not be sent. What you wrote is still here: please try again in a moment.";
      },
    );
  });
}
