import Foundation

enum BrowserAutomationScripts {
    static let snapshotScript = """
    (() => {
      const esc = (value) => {
        if (window.CSS && CSS.escape) return CSS.escape(value);
        return String(value).replace(/[^a-zA-Z0-9_-]/g, "\\\\$&");
      };
      const boundsFor = (el) => {
        const rect = el.getBoundingClientRect();
        return {
          x: Math.round(rect.x),
          y: Math.round(rect.y),
          width: Math.round(rect.width),
          height: Math.round(rect.height),
          centerX: Math.round(rect.x + rect.width / 2),
          centerY: Math.round(rect.y + rect.height / 2)
        };
      };
      const visible = (el) => {
        const style = window.getComputedStyle(el);
        const rect = el.getBoundingClientRect();
        return style.display !== "none" && style.visibility !== "hidden" && (rect.width > 0 || rect.height > 0);
      };
      const visibleText = () => {
        if (!document.body) return "";
        const pieces = [];
        let total = 0;
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        while (total < 12000) {
          const node = walker.nextNode();
          if (!node) break;
          const text = String(node.nodeValue || "").replace(/\\s+/g, " ").trim();
          if (!text) continue;
          const parent = node.parentElement;
          if (!parent || !visible(parent)) continue;
          pieces.push(text);
          total += text.length + 1;
        }
        return pieces.join("\\n").slice(0, 12000);
      };
      const selectorFor = (el) => {
        if (el.id) return "#" + esc(el.id);
        const testID = el.getAttribute("data-testid") || el.getAttribute("data-test") || el.getAttribute("aria-label");
        if (testID) return el.tagName.toLowerCase() + "[" + (el.getAttribute("data-testid") ? "data-testid" : el.getAttribute("data-test") ? "data-test" : "aria-label") + "=" + JSON.stringify(testID) + "]";
        const parts = [];
        let node = el;
        while (node && node.nodeType === Node.ELEMENT_NODE && node !== document.body && parts.length < 5) {
          let part = node.tagName.toLowerCase();
          const parent = node.parentElement;
          if (parent) {
            const siblings = Array.from(parent.children).filter((s) => s.tagName === node.tagName);
            if (siblings.length > 1) part += ":nth-of-type(" + (siblings.indexOf(node) + 1) + ")";
          }
          parts.unshift(part);
          node = parent;
        }
        return parts.join(" > ");
      };
      const labelFor = (el) => {
        const aria = el.getAttribute("aria-label") || el.getAttribute("title") || el.getAttribute("placeholder") || el.getAttribute("name") || "";
        const text = el.innerText || el.value || aria || el.id || el.tagName.toLowerCase();
        return String(text).replace(/\\s+/g, " ").trim().slice(0, 160);
      };
      const controls = Array.from(document.querySelectorAll("a, button, input, textarea, select, [role=button], [contenteditable=true]"))
        .filter(visible)
        .slice(0, 200)
        .map((el) => ({
          selector: selectorFor(el),
          tag: el.tagName.toLowerCase(),
          role: el.getAttribute("role") || "",
          type: el.getAttribute("type") || "",
          label: labelFor(el),
          value: (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.tagName === "SELECT") ? String(el.value || "").slice(0, 160) : "",
          href: el.href || "",
          bounds: boundsFor(el)
        }));
      const active = document.activeElement && document.activeElement !== document.body ? document.activeElement : null;
      return JSON.stringify({
        ok: true,
        url: location.href,
        title: document.title,
        viewport: {
          width: window.innerWidth,
          height: window.innerHeight,
          deviceScaleFactor: window.devicePixelRatio || 1
        },
        focusedElement: active ? {
          selector: selectorFor(active),
          tag: active.tagName.toLowerCase(),
          role: active.getAttribute("role") || "",
          type: active.getAttribute("type") || "",
          label: labelFor(active),
          value: (active.tagName === "INPUT" || active.tagName === "TEXTAREA" || active.tagName === "SELECT") ? String(active.value || "").slice(0, 160) : "",
          bounds: boundsFor(active)
        } : null,
        text: visibleText(),
        controls
      });
    })()
    """

    static func clickScript(selector: String?, x: Double?, y: Double?, allowDangerous: Bool) -> String {
        """
        (() => {
          const selector = \(optionalJSONLiteral(selector));
          const rawX = \(optionalNumberLiteral(x));
          const rawY = \(optionalNumberLiteral(y));
          const allowDangerous = \(allowDangerous ? "true" : "false");
          const hasPoint = Number.isFinite(rawX) && Number.isFinite(rawY);
          const pointFrom = (x, y) => {
            if (x >= 0 && x <= 1 && y >= 0 && y <= 1) {
              return { x: Math.round(x * window.innerWidth), y: Math.round(y * window.innerHeight), normalized: true };
            }
            return { x: Math.round(x), y: Math.round(y), normalized: false };
          };
          let point = hasPoint ? pointFrom(rawX, rawY) : null;
          let el = selector ? document.querySelector(selector) : null;
          if (!el && point) el = document.elementFromPoint(point.x, point.y);
          if (!el) return JSON.stringify({ ok: false, error: selector ? "selector_not_found" : "target_not_found", selector, x: rawX, y: rawY });
          if (!point) {
            el.scrollIntoView({ block: "center", inline: "center" });
            const rect = el.getBoundingClientRect();
            point = { x: Math.round(rect.x + rect.width / 2), y: Math.round(rect.y + rect.height / 2), normalized: false };
          }
          const label = String(el.innerText || el.value || el.getAttribute("aria-label") || el.getAttribute("title") || el.name || el.id || el.tagName).replace(/\\s+/g, " ").trim().slice(0, 160);
          const type = String(el.getAttribute("type") || "").toLowerCase();
          const dangerous = /\\b(send|submit|delete|remove|purchase|pay|confirm|authorize|approve|place order)\\b/i.test(label) || type === "submit";
          if (dangerous && !allowDangerous) {
            return JSON.stringify({ ok: false, error: "confirmation_required", needsConfirmation: true, selector, label, x: point.x, y: point.y });
          }
          const eventInit = { bubbles: true, cancelable: true, view: window, clientX: point.x, clientY: point.y, button: 0, buttons: 1 };
          for (const name of ["pointerover", "pointermove", "pointerdown", "mousedown", "pointerup", "mouseup", "click"]) {
            el.dispatchEvent(new MouseEvent(name, eventInit));
          }
          return JSON.stringify({ ok: true, selector, label, url: location.href, x: point.x, y: point.y, normalized: point.normalized });
        })()
        """
    }

    static func clickTargetScript(selector: String?, x: Double?, y: Double?, allowDangerous: Bool) -> String {
        """
        (() => {
          const selector = \(optionalJSONLiteral(selector));
          const rawX = \(optionalNumberLiteral(x));
          const rawY = \(optionalNumberLiteral(y));
          const allowDangerous = \(allowDangerous ? "true" : "false");
          const hasPoint = Number.isFinite(rawX) && Number.isFinite(rawY);
          const pointFrom = (x, y) => {
            if (x >= 0 && x <= 1 && y >= 0 && y <= 1) {
              return { x: Math.round(x * window.innerWidth), y: Math.round(y * window.innerHeight), normalized: true };
            }
            return { x: Math.round(x), y: Math.round(y), normalized: false };
          };
          let point = hasPoint ? pointFrom(rawX, rawY) : null;
          let el = selector ? document.querySelector(selector) : null;
          if (!el && point) el = document.elementFromPoint(point.x, point.y);
          if (!el) return JSON.stringify({ ok: false, error: selector ? "selector_not_found" : "target_not_found", selector, x: rawX, y: rawY });
          if (!point) {
            el.scrollIntoView({ block: "center", inline: "center" });
            const rect = el.getBoundingClientRect();
            point = { x: Math.round(rect.x + rect.width / 2), y: Math.round(rect.y + rect.height / 2), normalized: false };
          }
          const label = String(el.innerText || el.value || el.getAttribute("aria-label") || el.getAttribute("title") || el.name || el.id || el.tagName).replace(/\\s+/g, " ").trim().slice(0, 160);
          const type = String(el.getAttribute("type") || "").toLowerCase();
          const dangerous = /\\b(send|submit|delete|remove|purchase|pay|confirm|authorize|approve|place order)\\b/i.test(label) || type === "submit";
          if (dangerous && !allowDangerous) {
            return JSON.stringify({ ok: false, error: "confirmation_required", needsConfirmation: true, selector, label, x: point.x, y: point.y });
          }
          return JSON.stringify({ ok: true, selector, label, url: location.href, x: point.x, y: point.y, normalized: point.normalized });
        })()
        """
    }

    static func typeScript(selector: String, text: String, clear: Bool) -> String {
        """
        (() => {
          const selector = \(jsonLiteral(selector));
          const text = \(jsonLiteral(text));
          const clear = \(clear ? "true" : "false");
          const el = document.querySelector(selector);
          if (!el) return JSON.stringify({ ok: false, error: "selector_not_found", selector });
          el.scrollIntoView({ block: "center", inline: "center" });
          el.focus();
          const setNativeValue = (target, value) => {
            const proto = Object.getPrototypeOf(target);
            const descriptor = proto ? Object.getOwnPropertyDescriptor(proto, "value") : null;
            if (descriptor && descriptor.set) descriptor.set.call(target, value);
            else target.value = value;
          };
          const dispatchInput = (target, inputType, data) => {
            try {
              target.dispatchEvent(new InputEvent("input", { bubbles: true, inputType, data }));
            } catch (_) {
              target.dispatchEvent(new Event("input", { bubbles: true }));
            }
          };
          const before = "value" in el ? String(el.value || "") : String(el.textContent || "");
          const next = clear ? text : before + text;
          if ("value" in el) {
            setNativeValue(el, next);
            if (el.setSelectionRange && typeof next === "string") el.setSelectionRange(next.length, next.length);
          } else if (el.isContentEditable) {
            el.textContent = next;
          } else {
            el.textContent = next;
          }
          dispatchInput(el, clear ? "insertReplacementText" : "insertText", text);
          el.dispatchEvent(new Event("change", { bubbles: true }));
          return JSON.stringify({ ok: true, selector, url: location.href, value: next.slice(0, 300), cleared: clear });
        })()
        """
    }

    static func replaceTextScript(find: String, replacement: String, selector: String?, all: Bool) -> String {
        """
        (() => {
          const find = \(jsonLiteral(find));
          const replacement = \(jsonLiteral(replacement));
          const selector = \(optionalJSONLiteral(selector));
          const replaceAll = \(all ? "true" : "false");
          if (!find) return JSON.stringify({ ok: false, error: "missing_find" });
          const visible = (el) => {
            const style = window.getComputedStyle(el);
            const rect = el.getBoundingClientRect();
            return style.display !== "none" && style.visibility !== "hidden" && (rect.width > 0 || rect.height > 0);
          };
          const setNativeValue = (target, value) => {
            const proto = Object.getPrototypeOf(target);
            const descriptor = proto ? Object.getOwnPropertyDescriptor(proto, "value") : null;
            if (descriptor && descriptor.set) descriptor.set.call(target, value);
            else target.value = value;
          };
          const dispatchInput = (target, inputType, data) => {
            try {
              target.dispatchEvent(new InputEvent("input", { bubbles: true, inputType, data }));
            } catch (_) {
              target.dispatchEvent(new Event("input", { bubbles: true }));
            }
          };
          const replaceInString = (value) => {
            const source = String(value || "");
            if (!source.includes(find)) return { value: source, count: 0 };
            if (!replaceAll) return { value: source.replace(find, replacement), count: 1 };
            return { value: source.split(find).join(replacement), count: source.split(find).length - 1 };
          };
          const changed = [];
          const candidates = selector
            ? Array.from(document.querySelectorAll(selector))
            : Array.from(document.querySelectorAll("input, textarea, [contenteditable=true]"));
          for (const el of candidates) {
            if (!visible(el)) continue;
            const before = "value" in el ? String(el.value || "") : String(el.textContent || "");
            const result = replaceInString(before);
            if (result.count <= 0) continue;
            el.focus();
            if ("value" in el) {
              setNativeValue(el, result.value);
              if (el.setSelectionRange) el.setSelectionRange(result.value.length, result.value.length);
            } else {
              el.textContent = result.value;
            }
            dispatchInput(el, "insertReplacementText", replacement);
            el.dispatchEvent(new Event("change", { bubbles: true }));
            changed.push({ selector: selector || (el.id ? "#" + el.id : el.tagName.toLowerCase()), replacements: result.count });
            if (!replaceAll) break;
          }
          if (changed.length > 0) {
            return JSON.stringify({ ok: true, replacements: changed.reduce((sum, item) => sum + item.replacements, 0), changed, url: location.href });
          }
          const googleEditor = location.hostname === "docs.google.com" && /^\\/(document|presentation|spreadsheets)\\//.test(location.pathname);
          return JSON.stringify({
            ok: false,
            error: googleEditor ? "editor_surface_requires_find_replace" : "text_not_found_in_editable_controls",
            find,
            url: location.href,
            hint: googleEditor
              ? "Google editor canvas text is not directly editable through DOM replacement. Open Find and replace, then use astra-browser set-value on the Find and Replace fields by selector."
              : "No editable input, textarea, or contenteditable element contained the requested text. Use snapshot --mode controls to find a specific field selector."
          });
        })()
        """
    }

    static func keypressScript(key: String, modifiers: [String]) -> String {
        """
        (() => {
          const key = \(jsonLiteral(key));
          const modifiers = new Set(\(stringArrayLiteral(modifiers)));
          const target = document.activeElement && document.activeElement !== document.body ? document.activeElement : document.body;
          const lower = new Set(Array.from(modifiers).map((m) => String(m).toLowerCase()));
          const init = {
            key,
            code: key.length === 1 ? "Key" + key.toUpperCase() : key,
            bubbles: true,
            cancelable: true,
            view: window,
            metaKey: lower.has("command") || lower.has("cmd") || lower.has("meta"),
            ctrlKey: lower.has("control") || lower.has("ctrl"),
            altKey: lower.has("option") || lower.has("alt"),
            shiftKey: lower.has("shift")
          };
          target.dispatchEvent(new KeyboardEvent("keydown", init));
          target.dispatchEvent(new KeyboardEvent("keyup", init));
          return JSON.stringify({ ok: true, key, modifiers: Array.from(modifiers), focusedTag: target.tagName ? target.tagName.toLowerCase() : "" });
        })()
        """
    }

    static func insertTextScript(_ text: String) -> String {
        """
        (() => {
          const text = \(jsonLiteral(text));
          const target = document.activeElement && document.activeElement !== document.body ? document.activeElement : null;
          if (!target) return JSON.stringify({ ok: false, error: "no_focused_element" });
          target.focus();
          if ("value" in target) {
            const start = target.selectionStart ?? String(target.value || "").length;
            const end = target.selectionEnd ?? start;
            const before = String(target.value || "").slice(0, start);
            const after = String(target.value || "").slice(end);
            target.value = before + text + after;
            const cursor = start + text.length;
            if (target.setSelectionRange) target.setSelectionRange(cursor, cursor);
          } else if (document.queryCommandSupported && document.queryCommandSupported("insertText")) {
            document.execCommand("insertText", false, text);
          } else {
            target.textContent = String(target.textContent || "") + text;
          }
          target.dispatchEvent(new Event("input", { bubbles: true }));
          target.dispatchEvent(new Event("change", { bubbles: true }));
          return JSON.stringify({ ok: true, textLength: text.length, focusedTag: target.tagName ? target.tagName.toLowerCase() : "" });
        })()
        """
    }

    static func jsonLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }

    static func optionalJSONLiteral(_ value: String?) -> String {
        guard let value else { return "null" }
        return jsonLiteral(value)
    }

    static func optionalNumberLiteral(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "null" }
        return String(value)
    }

    static func stringArrayLiteral(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let literal = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return literal
    }
}
