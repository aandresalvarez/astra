import Foundation

enum BrowserAutomationScripts {
    static let pageReadMessageHandlerName = "astraPageRead"

    static let debugInstrumentationScript = """
    (() => {
      if (window.__astraDebugInstalled) return true;
      window.__astraDebugInstalled = true;
      const maxEvents = 80;
      const trim = (value, max = 500) => String(value ?? "").replace(/\\s+/g, " ").trim().slice(0, max);
      const now = () => new Date().toISOString();
      const redactedURL = (value) => {
        try {
          const url = new URL(String(value), location.href);
          url.username = "";
          url.password = "";
          url.search = "";
          url.hash = "";
          return url.toString();
        } catch (_) {
          return trim(value, 300);
        }
      };
      const push = (name, event) => {
        const bucketName = "__astra" + name;
        const bucket = Array.isArray(window[bucketName]) ? window[bucketName] : [];
        bucket.push(Object.assign({ timestamp: now() }, event));
        while (bucket.length > maxEvents) bucket.shift();
        window[bucketName] = bucket;
      };

      window.__astraConsoleEvents = Array.isArray(window.__astraConsoleEvents) ? window.__astraConsoleEvents : [];
      window.__astraNavigationEvents = Array.isArray(window.__astraNavigationEvents) ? window.__astraNavigationEvents : [];
      window.__astraNetworkEvents = Array.isArray(window.__astraNetworkEvents) ? window.__astraNetworkEvents : [];

      const wrapConsole = (level) => {
        const original = console[level];
        if (typeof original !== "function") return;
        console[level] = function(...args) {
          try {
            push("ConsoleEvents", {
              level,
              message: trim(args.map((arg) => {
                if (arg instanceof Error) return arg.name + ": " + arg.message;
                if (typeof arg === "string") return arg;
                try { return JSON.stringify(arg); } catch (_) { return String(arg); }
              }).join(" "), 700)
            });
          } catch (_) {}
          return original.apply(this, args);
        };
      };
      wrapConsole("error");
      wrapConsole("warn");

      window.addEventListener("error", (event) => {
        push("ConsoleEvents", {
          level: "pageerror",
          message: trim(event.message || event.error?.message || "error", 700),
          source: redactedURL(event.filename || ""),
          line: event.lineno || 0,
          column: event.colno || 0
        });
      });
      window.addEventListener("unhandledrejection", (event) => {
        push("ConsoleEvents", {
          level: "unhandledrejection",
          message: trim(event.reason?.message || event.reason || "unhandled rejection", 700)
        });
      });
      for (const type of ["DOMContentLoaded", "load", "hashchange", "popstate", "beforeunload"]) {
        window.addEventListener(type, () => {
          push("NavigationEvents", { type, url: redactedURL(location.href) });
        });
      }

      if (typeof window.fetch === "function" && !window.fetch.__astraWrapped) {
        const originalFetch = window.fetch;
        const wrappedFetch = async function(input, init) {
          const started = Date.now();
          const method = trim(init?.method || input?.method || "GET", 20);
          const url = redactedURL(input?.url || input);
          try {
            const response = await originalFetch.apply(this, arguments);
            if (!response.ok) {
              push("NetworkEvents", {
                type: "fetch",
                method,
                url,
                status: response.status,
                elapsedMs: Date.now() - started
              });
            }
            return response;
          } catch (error) {
            push("NetworkEvents", {
              type: "fetch",
              method,
              url,
              error: trim(error?.message || error, 500),
              elapsedMs: Date.now() - started
            });
            throw error;
          }
        };
        wrappedFetch.__astraWrapped = true;
        window.fetch = wrappedFetch;
      }

      if (window.XMLHttpRequest && !window.XMLHttpRequest.prototype.__astraWrapped) {
        const originalOpen = window.XMLHttpRequest.prototype.open;
        const originalSend = window.XMLHttpRequest.prototype.send;
        window.XMLHttpRequest.prototype.open = function(method, url) {
          this.__astraRequest = { method: trim(method || "GET", 20), url: redactedURL(url), started: Date.now() };
          return originalOpen.apply(this, arguments);
        };
        window.XMLHttpRequest.prototype.send = function() {
          const request = this.__astraRequest || { method: "GET", url: "", started: Date.now() };
          this.addEventListener("loadend", () => {
            if (this.status >= 400) {
              push("NetworkEvents", {
                type: "xhr",
                method: request.method,
                url: request.url,
                status: this.status,
                elapsedMs: Date.now() - request.started
              });
            }
          });
          this.addEventListener("error", () => {
            push("NetworkEvents", {
              type: "xhr",
              method: request.method,
              url: request.url,
              error: "network_error",
              elapsedMs: Date.now() - request.started
            });
          });
          return originalSend.apply(this, arguments);
        };
        window.XMLHttpRequest.prototype.__astraWrapped = true;
      }

      push("NavigationEvents", { type: "instrumented", url: redactedURL(location.href) });
      return true;
    })()
    """

    static var debugReadScript: String {
        """
    (() => {
      try { \(debugInstrumentationScript); } catch (_) {}
      return JSON.stringify({
        ok: true,
        url: location.href,
        title: document.title,
        consoleEvents: Array.isArray(window.__astraConsoleEvents) ? window.__astraConsoleEvents.slice(-80) : [],
        navigationEvents: Array.isArray(window.__astraNavigationEvents) ? window.__astraNavigationEvents.slice(-80) : [],
        networkEvents: Array.isArray(window.__astraNetworkEvents) ? window.__astraNetworkEvents.slice(-80) : []
      });
    })()
    """
    }

    static func pageReadFrameScript(limit: Int) -> String {
        """
        (() => {
          \(pageReadCollectorScript)
          return JSON.stringify(window.__astraCollectPageReadFrame({
            source: "controlled_chromium",
            limit: \(max(1_000, limit))
          }));
        })()
        """
    }

    static func embeddedPageReadReporterScript(messageHandlerName: String = pageReadMessageHandlerName) -> String {
        """
        (() => {
          if (window.__astraPageReadReporterInstalled) return true;
          window.__astraPageReadReporterInstalled = true;
          \(pageReadCollectorScript)
          const postNativePageRead = (payload) => {
            try {
              window.webkit.messageHandlers.\(messageHandlerName).postMessage(payload);
            } catch (_) {}
          };
          const broadcastPageReadRequest = (request) => {
            const frames = Array.from(document.querySelectorAll("iframe, frame"));
            for (let index = 0; index < frames.length; index += 1) {
              try {
                frames[index].contentWindow?.postMessage(Object.assign({}, request, {
                  parentFrameID: request.frameID || "main",
                  frameID: (request.frameID || "main") + "." + index
                }), "*");
              } catch (_) {}
            }
          };
          window.__astraPageReadHandleRequest = (request) => {
            const limit = Math.max(1000, Math.min(Number(request.limit || 50000), 250000));
            const report = window.__astraCollectPageReadFrame({
              source: "embedded_webkit",
              frameID: request.frameID || "main",
              parentFrameID: request.parentFrameID || "",
              limit
            });
            report.requestID = request.requestID || "";
            postNativePageRead(report);
            broadcastPageReadRequest(request);
          };
          window.addEventListener("message", (event) => {
            if (window.parent === window || event.source !== window.parent) return;
            const request = event.data || {};
            if (request.__astraPageRead !== true || !request.requestID) return;
            window.__astraPageReadHandleRequest(request);
          });
          return true;
        })()
        """
    }

    static func embeddedPageReadDispatchScript(requestID: String, limit: Int) -> String {
        """
        (() => {
          const request = {
            __astraPageRead: true,
            requestID: \(jsStringLiteral(requestID)),
            frameID: "main",
            parentFrameID: "",
            limit: \(max(1_000, limit))
          };
          let dispatched = typeof window.__astraPageReadHandleRequest === "function";
          if (dispatched) {
            window.__astraPageReadHandleRequest(request);
          }
          return JSON.stringify({ ok: true, dispatched, requestID: request.requestID, url: location.href, title: document.title });
        })()
        """
    }

    private static var pageReadCollectorScript: String {
        """
          if (typeof window.__astraCollectPageReadFrame !== "function") {
            window.__astraCollectPageReadFrame = (options) => {
              const limit = Math.max(1000, Math.min(Number(options?.limit || 50000), 250000));
              const compact = (value, max = 500) => String(value ?? "").replace(/\\s+/g, " ").trim().slice(0, max);
              const visible = (el) => {
                try {
                  if (!el) return false;
                  const style = window.getComputedStyle(el);
                  const rect = el.getBoundingClientRect();
                  return style.display !== "none"
                    && style.visibility !== "hidden"
                    && style.opacity !== "0"
                    && (rect.width > 0 || rect.height > 0);
                } catch (_) {
                  return true;
                }
              };
              const readableText = () => {
                if (!document.body) return { text: "", textLength: 0, truncated: false };
                const pieces = [];
                let returnedLength = 0;
                let textLength = 0;
                let truncated = false;
                const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
                while (true) {
                  const node = walker.nextNode();
                  if (!node) break;
                  const text = String(node.nodeValue || "").replace(/\\s+/g, " ").trim();
                  if (!text) continue;
                  const parent = node.parentElement;
                  if (!parent || !visible(parent)) continue;
                  textLength += text.length + 1;
                  if (returnedLength >= limit) {
                    truncated = true;
                    continue;
                  }
                  const remaining = limit - returnedLength;
                  const next = text.length > remaining ? text.slice(0, remaining) : text;
                  pieces.push(next);
                  returnedLength += next.length + 1;
                  if (text.length > remaining) truncated = true;
                }
                return { text: pieces.join("\\n").slice(0, limit), textLength, truncated };
              };
              const childFrames = () => {
                return Array.from(document.querySelectorAll("iframe, frame")).map((frame, index) => {
                  const sandbox = frame.getAttribute("sandbox");
                  const sandboxTokens = String(sandbox || "").split(/\\s+/).filter(Boolean);
                  return {
                    index,
                    url: frame.src || frame.getAttribute("src") || "",
                    title: frame.getAttribute("title") || frame.getAttribute("name") || "",
                    sandboxed: sandbox !== null,
                    scriptsAllowed: sandbox === null || sandboxTokens.includes("allow-scripts")
                  };
                });
              };
              const kind = (() => {
                const type = String(document.contentType || "").toLowerCase();
                if (type.includes("pdf")) return "pdf";
                if (document.querySelector("canvas")) return "canvas";
                return "html";
              })();
              const text = readableText();
              const warnings = [];
              if (kind === "canvas") warnings.push("Page contains canvas content that may not be represented in DOM text.");
              if (kind === "pdf") warnings.push("PDF viewer content may require a PDF-specific reader.");
              return {
                ok: true,
                frameID: options?.frameID || "main",
                parentFrameID: options?.parentFrameID || "",
                url: location.href,
                title: document.title,
                contentKind: kind,
                text: text.text,
                textLength: text.textLength,
                returnedTextLength: text.text.length,
                truncated: text.truncated,
                accessible: text.text.length > 0,
                source: options?.source || "browser",
                childFrames: childFrames(),
                warnings
              };
            };
          }
        """
    }

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
        return style.display !== "none"
          && style.visibility !== "hidden"
          && style.opacity !== "0"
          && (rect.width > 0 || rect.height > 0);
      };
      const disabled = (el) => Boolean(el.disabled) || el.getAttribute("aria-disabled") === "true" || el.getAttribute("disabled") !== null;
      const isContentEditableElement = (el) => Boolean(el) && (el.isContentEditable || String(el.getAttribute("contenteditable") || "").toLowerCase() === "true");
      const roleFor = (el) => {
        const explicit = el.getAttribute("role");
        if (explicit) return explicit;
        const tag = el.tagName.toLowerCase();
        const type = String(el.getAttribute("type") || "").toLowerCase();
        if (tag === "button" || type === "button" || type === "submit") return "button";
        if (tag === "a" && el.href) return "link";
        if (tag === "input" || tag === "textarea" || isContentEditableElement(el)) return "textbox";
        if (tag === "select") return "combobox";
        return "";
      };
      const labelledText = (el) => {
        const ids = String(el.getAttribute("aria-labelledby") || "").split(/\\s+/).filter(Boolean);
        const byID = ids.map((id) => document.getElementById(id)?.innerText || "").filter(Boolean).join(" ");
        if (byID) return byID;
        if (el.id) {
          const label = document.querySelector("label[for='" + esc(el.id) + "']");
          if (label?.innerText) return label.innerText;
        }
        const parentLabel = el.closest("label");
        if (parentLabel?.innerText) return parentLabel.innerText;
        return "";
      };
      const valueControlForTextNode = (el) => {
        let node = el;
        while (node && node !== document.body) {
          const tag = node.tagName ? node.tagName.toLowerCase() : "";
          if (tag === "input" || tag === "textarea" || tag === "select" || isContentEditableElement(node)) return node;
          node = node.parentElement;
        }
        return null;
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
          const valueControl = valueControlForTextNode(parent);
          if (valueControl && isSensitiveValueControl(valueControl)) continue;
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
        const aria = el.getAttribute("aria-label") || labelledText(el) || el.getAttribute("title") || el.getAttribute("placeholder") || el.getAttribute("name") || "";
        const text = aria || el.innerText || el.value || el.id || el.tagName.toLowerCase();
        return String(text).replace(/\\s+/g, " ").trim().slice(0, 160);
      };
      const containsAny = (text, needles) => needles.some((needle) => text.includes(needle));
      const sensitiveFieldTerms = [
        "password", "passcode", "secret", "token", "api key", "api-key", "api_token", "apikey",
        "access token", "refresh token", "auth token", "bearer token",
        "oauth", "client secret", "private key", "mfa", "2fa", "two factor",
        "two-factor", "verification code", "security code", "one-time",
        "one time", "otp", "totp", "ssn", "social security", "credit card",
        "dob", "date of birth", "birth date", "birthdate", "mrn",
        "medical record", "medical record number", "patient id", "patient identifier",
        "health record", "card number", "cardholder", "card holder",
        "name on card", "cvv", "cvc", "payment", "billing"
      ];
      const sensitiveAutocompleteTerms = [
        "current-password", "new-password", "one-time-code",
        "cc-name", "cc-given-name", "cc-additional-name", "cc-family-name",
        "cc-number", "cc-exp", "cc-exp-month", "cc-exp-year",
        "cc-csc", "cc-type"
      ];
      const isSensitiveValueControl = (el) => {
        const type = String(el.getAttribute("type") || "").toLowerCase();
        if (type === "password" || type === "hidden") return true;
        const autocomplete = String(el.getAttribute("autocomplete") || "").toLowerCase();
        if (containsAny(autocomplete, sensitiveAutocompleteTerms)) return true;
        const text = [
          selectorFor(el),
          labelFor(el),
          el.getAttribute("name") || "",
          el.getAttribute("role") || "",
          el.tagName.toLowerCase(),
          type,
          el.getAttribute("placeholder") || "",
          el.getAttribute("data-testid") || el.getAttribute("data-test") || "",
          el.href || "",
          autocomplete
        ].join(" ").toLowerCase();
        return containsAny(text, sensitiveFieldTerms);
      };
      const editableValueFor = (el) => {
        if (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.tagName === "SELECT") {
          return String(el.value || "");
        }
        if (isContentEditableElement(el)) {
          return String(el.textContent || "");
        }
        return "";
      };
      const valueForSnapshot = (el) => {
        const value = editableValueFor(el).slice(0, 160);
        if (!value) return "";
        return isSensitiveValueControl(el) ? "[redacted-sensitive-input]" : value;
      };
      const labelForSnapshot = (el) => {
        const label = labelFor(el);
        const value = editableValueFor(el).replace(/\\s+/g, " ").trim().slice(0, 160);
        if (value && isSensitiveValueControl(el) && (label === value || label.includes(value))) {
          return "[redacted-sensitive-input]";
        }
        return label;
      };
      const frameLabelFor = (frame) => {
        const title = frame.getAttribute("title") || frame.getAttribute("name") || frame.getAttribute("aria-label") || frame.src || selectorFor(frame);
        return String(title || "").replace(/\\s+/g, " ").trim().slice(0, 160);
      };
      const allControls = () => {
        const selector = "a, button, input, textarea, select, [role], [contenteditable=true], [tabindex]";
        const out = [];
        const seen = new Set();
        const collect = (root, depth, framePath) => {
          if (!root || depth > 3) return;
          for (const el of Array.from(root.querySelectorAll(selector))) {
            if (!seen.has(el)) {
              seen.add(el);
              out.push({ el, shadowDepth: depth, framePath });
            }
            if (el.shadowRoot) collect(el.shadowRoot, depth + 1, framePath);
          }
          const frames = root.querySelectorAll ? Array.from(root.querySelectorAll("iframe, frame")) : [];
          for (const frame of frames) {
            try {
              if (frame.contentDocument) collect(frame.contentDocument, depth, framePath.concat(frameLabelFor(frame)));
            } catch (_) {}
          }
        };
        collect(document, 0, []);
        return out;
      };
      const viewportInfoFor = (el) => {
        const rect = el.getBoundingClientRect();
        const inViewport = rect.bottom >= 0
          && rect.right >= 0
          && rect.x <= window.innerWidth
          && rect.y <= window.innerHeight;
        return {
          inViewport,
          x: Math.round(rect.x),
          y: Math.round(rect.y),
          area: Math.round(Math.max(0, rect.width) * Math.max(0, rect.height))
        };
      };
      const compareViewportOrder = (a, b) => {
        const av = a.viewportInfo;
        const bv = b.viewportInfo;
        if (av.inViewport !== bv.inViewport) return av.inViewport ? -1 : 1;
        const ay = av.inViewport ? Math.max(0, av.y) : Math.abs(av.y);
        const by = bv.inViewport ? Math.max(0, bv.y) : Math.abs(bv.y);
        if (ay !== by) return ay - by;
        if (av.x !== bv.x) return av.x - bv.x;
        return bv.area - av.area;
      };
      const controls = allControls()
        .filter((entry) => visible(entry.el))
        .map((entry) => Object.assign(entry, { viewportInfo: viewportInfoFor(entry.el) }))
        .sort(compareViewportOrder)
        .slice(0, 300)
        .map((entry) => {
          const el = entry.el;
          return ({
          selector: selectorFor(el),
          tag: el.tagName.toLowerCase(),
          role: roleFor(el),
          type: el.getAttribute("type") || "",
          label: labelForSnapshot(el),
          name: el.getAttribute("name") || "",
          placeholder: el.getAttribute("placeholder") || "",
          autocomplete: el.getAttribute("autocomplete") || "",
          testID: el.getAttribute("data-testid") || el.getAttribute("data-test") || "",
          disabled: disabled(el),
          actionable: !disabled(el) && visible(el),
          value: valueForSnapshot(el),
          href: el.href || "",
          framePath: entry.framePath,
          shadowDepth: entry.shadowDepth,
          inViewport: entry.viewportInfo.inViewport,
          bounds: boundsFor(el)
        });
        });
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
          label: labelForSnapshot(active),
          name: active.getAttribute("name") || "",
          autocomplete: active.getAttribute("autocomplete") || "",
          value: valueForSnapshot(active),
          bounds: boundsFor(active)
        } : null,
        text: visibleText(),
        controls
      });
    })()
    """

    static func targetInfoScript(
        selector: String?,
        x: Double?,
        y: Double?,
        allowDangerous: Bool,
        label: String? = nil,
        role: String? = nil,
        text: String? = nil,
        placeholder: String? = nil,
        testID: String? = nil
    ) -> String {
        """
        (() => {
          \(targetResolutionPrelude(selector: selector, x: x, y: y, allowDangerous: allowDangerous, label: label, role: role, text: text, placeholder: placeholder, testID: testID))
          return JSON.stringify(publicTarget(resolveTarget()));
        })()
        """
    }

    static func clickScript(
        selector: String?,
        x: Double?,
        y: Double?,
        allowDangerous: Bool,
        label: String? = nil,
        role: String? = nil,
        text: String? = nil,
        placeholder: String? = nil,
        testID: String? = nil
    ) -> String {
        """
        (() => {
          \(targetResolutionPrelude(selector: selector, x: x, y: y, allowDangerous: allowDangerous, label: label, role: role, text: text, placeholder: placeholder, testID: testID))
          const target = resolveTarget();
          if (!target.ok) return JSON.stringify(publicTarget(target));
          const el = target.el;
          const point = target.point;
          try { el.focus({ preventScroll: true }); } catch (_) { try { el.focus(); } catch (_) {} }
          const eventInit = { bubbles: true, cancelable: true, view: window, clientX: point.x, clientY: point.y, button: 0, buttons: 1 };
          for (const name of ["pointerover", "pointermove", "mouseover", "pointerdown", "mousedown", "pointerup", "mouseup", "click"]) {
            el.dispatchEvent(new MouseEvent(name, eventInit));
          }
          const result = publicTarget(target);
          result.ok = true;
          result.clicked = true;
          result.url = location.href;
          return JSON.stringify(result);
        })()
        """
    }

    static func doubleClickScript(
        selector: String?,
        x: Double?,
        y: Double?,
        allowDangerous: Bool,
        label: String? = nil,
        role: String? = nil,
        text: String? = nil,
        placeholder: String? = nil,
        testID: String? = nil
    ) -> String {
        """
        (() => {
          \(targetResolutionPrelude(selector: selector, x: x, y: y, allowDangerous: allowDangerous, label: label, role: role, text: text, placeholder: placeholder, testID: testID))
          const target = resolveTarget();
          if (!target.ok) return JSON.stringify(publicTarget(target));
          const el = target.el;
          const point = target.point;
          try { el.focus({ preventScroll: true }); } catch (_) { try { el.focus(); } catch (_) {} }
          const base = { bubbles: true, cancelable: true, view: window, clientX: point.x, clientY: point.y, button: 0, buttons: 1 };
          const dispatchMouse = (name, detail) => {
            const init = Object.assign({}, base, { detail });
            el.dispatchEvent(new MouseEvent(name, init));
          };
          for (const name of ["pointerover", "pointermove", "mouseover"]) dispatchMouse(name, 0);
          for (const detail of [1, 2]) {
            for (const name of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]) dispatchMouse(name, detail);
          }
          dispatchMouse("dblclick", 2);
          const result = publicTarget(target);
          result.ok = true;
          result.clicked = true;
          result.doubleClicked = true;
          result.url = location.href;
          return JSON.stringify(result);
        })()
        """
    }

    static func clickTargetScript(
        selector: String?,
        x: Double?,
        y: Double?,
        allowDangerous: Bool,
        label: String? = nil,
        role: String? = nil,
        text: String? = nil,
        placeholder: String? = nil,
        testID: String? = nil
    ) -> String {
        targetInfoScript(
            selector: selector,
            x: x,
            y: y,
            allowDangerous: allowDangerous,
            label: label,
            role: role,
            text: text,
            placeholder: placeholder,
            testID: testID
        )
    }

    static func typeScript(
        selector: String?,
        text: String,
        clear: Bool,
        label: String? = nil,
        role: String? = nil,
        placeholder: String? = nil,
        testID: String? = nil
    ) -> String {
        """
        (() => {
          \(targetResolutionPrelude(selector: selector, x: nil, y: nil, allowDangerous: true, label: label, role: role, text: nil, placeholder: placeholder, testID: testID))
          const text = \(jsonLiteral(text));
          const clear = \(clear ? "true" : "false");
          const target = resolveTarget();
          if (!target.ok) return JSON.stringify(publicTarget(target));
          const el = target.el;
          if (!("value" in el) && !el.isContentEditable && el.tagName !== "SELECT") {
            const result = publicTarget(target);
            result.ok = false;
            result.error = "target_not_editable";
            return JSON.stringify(result);
          }
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
          const sensitiveResultTerms = [
            "password", "passcode", "secret", "token", "api key", "api-key", "api_token", "apikey",
            "access token", "refresh token", "auth token", "bearer token",
            "oauth", "client secret", "private key", "mfa", "2fa", "two factor",
            "two-factor", "verification code", "security code", "one-time",
            "one time", "otp", "totp", "ssn", "social security", "credit card",
            "dob", "date of birth", "birth date", "birthdate", "mrn",
            "medical record", "medical record number", "patient id", "patient identifier",
            "health record", "card number", "cardholder", "card holder",
            "name on card", "cvv", "cvc", "payment", "billing"
          ];
          const sensitiveAutocompleteTerms = [
            "current-password", "new-password", "one-time-code",
            "cc-name", "cc-given-name", "cc-additional-name", "cc-family-name",
            "cc-number", "cc-exp", "cc-exp-month", "cc-exp-year",
            "cc-csc", "cc-type"
          ];
          const redactedInputValue = "[redacted-sensitive-input]";
          const includesAny = (value, terms) => terms.some((term) => value.includes(term));
          const sensitiveResultTarget = (target) => {
            const type = String(target.getAttribute("type") || "").toLowerCase();
            if (type === "password" || type === "hidden") return true;
            const autocomplete = String(target.getAttribute("autocomplete") || "").toLowerCase();
            if (includesAny(autocomplete, sensitiveAutocompleteTerms)) return true;
            const text = [
              selectorFor(target),
              labelFor(target),
              target.getAttribute("name") || "",
              roleFor(target),
              target.tagName.toLowerCase(),
              type,
              target.getAttribute("placeholder") || "",
              target.getAttribute("data-testid") || target.getAttribute("data-test") || "",
              autocomplete
            ].join(" ").toLowerCase();
            return includesAny(text, sensitiveResultTerms);
          };
          const redactSensitiveResultTarget = (result, target, value) => {
            if (!sensitiveResultTarget(target)) return result;
            result.value = redactedInputValue;
            const normalizedValue = norm(value);
            if (normalizedValue && norm(result.label).includes(normalizedValue)) {
              result.label = redactedInputValue;
            }
            return result;
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
          const result = publicTarget(target);
          result.ok = true;
          result.url = location.href;
          result.value = next.slice(0, 300);
          redactSensitiveResultTarget(result, el, next);
          result.cleared = clear;
          return JSON.stringify(result);
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
            findLength: find.length,
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

    private static func targetResolutionPrelude(
        selector: String?,
        x: Double?,
        y: Double?,
        allowDangerous: Bool,
        label: String?,
        role: String?,
        text: String?,
        placeholder: String?,
        testID: String?
    ) -> String {
        """
          const selector = \(optionalJSONLiteral(selector));
          const rawX = \(optionalNumberLiteral(x));
          const rawY = \(optionalNumberLiteral(y));
          const locatorLabel = \(optionalJSONLiteral(label));
          const locatorRole = \(optionalJSONLiteral(role));
          const locatorText = \(optionalJSONLiteral(text));
          const locatorPlaceholder = \(optionalJSONLiteral(placeholder));
          const locatorTestID = \(optionalJSONLiteral(testID));
          const allowDangerous = \(allowDangerous ? "true" : "false");
          const hasPoint = Number.isFinite(rawX) && Number.isFinite(rawY);
          const pointFrom = (x, y) => {
            if (x >= 0 && x <= 1 && y >= 0 && y <= 1) {
              return { x: Math.round(x * window.innerWidth), y: Math.round(y * window.innerHeight), normalized: true };
            }
            return { x: Math.round(x), y: Math.round(y), normalized: false };
          };
          const esc = (value) => {
            if (window.CSS && CSS.escape) return CSS.escape(value);
            return String(value).replace(/[^a-zA-Z0-9_-]/g, "\\\\$&");
          };
          const visible = (el) => {
            const style = window.getComputedStyle(el);
            const rect = el.getBoundingClientRect();
            return style.display !== "none"
              && style.visibility !== "hidden"
              && style.opacity !== "0"
              && (rect.width > 0 || rect.height > 0);
          };
          const disabled = (el) => Boolean(el.disabled) || el.getAttribute("aria-disabled") === "true" || el.getAttribute("disabled") !== null;
          const roleFor = (el) => {
            const explicit = el.getAttribute("role");
            if (explicit) return explicit;
            const tag = el.tagName.toLowerCase();
            const type = String(el.getAttribute("type") || "").toLowerCase();
            if (tag === "button" || type === "button" || type === "submit") return "button";
            if (tag === "a" && el.href) return "link";
            if (tag === "input" || tag === "textarea" || el.isContentEditable) return "textbox";
            if (tag === "select") return "combobox";
            return "";
          };
          const labelledText = (el) => {
            const ids = String(el.getAttribute("aria-labelledby") || "").split(/\\s+/).filter(Boolean);
            const byID = ids.map((id) => document.getElementById(id)?.innerText || "").filter(Boolean).join(" ");
            if (byID) return byID;
            if (el.id) {
              const label = document.querySelector("label[for='" + esc(el.id) + "']");
              if (label?.innerText) return label.innerText;
            }
            const parentLabel = el.closest("label");
            if (parentLabel?.innerText) return parentLabel.innerText;
            return "";
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
            const aria = el.getAttribute("aria-label") || labelledText(el) || el.getAttribute("title") || el.getAttribute("placeholder") || el.getAttribute("name") || "";
            const text = aria || el.innerText || el.value || el.id || el.tagName.toLowerCase();
            return String(text).replace(/\\s+/g, " ").trim().slice(0, 160);
          };
          const controlSelector = "a, button, input, textarea, select, [role], [contenteditable=true], [tabindex]";
          const allControls = () => {
            const out = [];
            const seen = new Set();
            const collect = (root, depth) => {
              if (!root || depth > 3) return;
              for (const el of Array.from(root.querySelectorAll(controlSelector))) {
                if (!seen.has(el)) {
                  seen.add(el);
                  out.push(el);
                }
                if (el.shadowRoot) collect(el.shadowRoot, depth + 1);
              }
            };
            collect(document, 0);
            return out;
          };
          const norm = (value) => String(value || "").replace(/\\s+/g, " ").trim().toLowerCase();
          const contains = (haystack, needle) => !needle || norm(haystack).includes(norm(needle));
          const locatorSummary = () => ({
            selector: Boolean(selector),
            point: hasPoint,
            label: Boolean(locatorLabel),
            role: Boolean(locatorRole),
            text: Boolean(locatorText),
            placeholder: Boolean(locatorPlaceholder),
            testID: Boolean(locatorTestID)
          });
          const matchesLocator = (el) => {
            if (locatorRole && !contains(roleFor(el), locatorRole)) return false;
            if (locatorPlaceholder && !contains(el.getAttribute("placeholder") || "", locatorPlaceholder)) return false;
            if (locatorTestID) {
              const id = el.getAttribute("data-testid") || el.getAttribute("data-test") || "";
              if (!contains(id, locatorTestID)) return false;
            }
            if (locatorLabel) {
              const values = [labelFor(el), el.getAttribute("aria-label") || "", labelledText(el), el.value || "", el.name || "", el.id || ""];
              if (!values.some((value) => contains(value, locatorLabel))) return false;
            }
            if (locatorText) {
              const values = [el.innerText || "", el.textContent || "", el.value || ""];
              if (!values.some((value) => contains(value, locatorText))) return false;
            }
            return true;
          };
          const scoreFor = (el) => {
            let score = 0;
            const label = norm(labelFor(el));
            const role = norm(roleFor(el));
            if (locatorRole && role === norm(locatorRole)) score += 25;
            if (locatorLabel && label === norm(locatorLabel)) score += 40;
            if (locatorLabel && label.startsWith(norm(locatorLabel))) score += 20;
            if (locatorPlaceholder && norm(el.getAttribute("placeholder") || "") === norm(locatorPlaceholder)) score += 25;
            if (locatorTestID && norm(el.getAttribute("data-testid") || el.getAttribute("data-test") || "") === norm(locatorTestID)) score += 50;
            if (visible(el)) score += 10;
            if (!disabled(el)) score += 10;
            return score;
          };
          const actionablePoint = (el, initialPoint) => {
            let point = initialPoint;
            if (!point) {
              el.scrollIntoView({ block: "center", inline: "center" });
              const rect = el.getBoundingClientRect();
              point = { x: Math.round(rect.x + rect.width / 2), y: Math.round(rect.y + rect.height / 2), normalized: false };
            }
            if (point.x < 0 || point.y < 0 || point.x > window.innerWidth || point.y > window.innerHeight) {
              return { ok: false, error: "target_outside_viewport", point };
            }
            const top = document.elementFromPoint(point.x, point.y);
            if (top && (top === el || el.contains(top) || top.contains(el))) {
              return { ok: true, point, top };
            }
            return { ok: false, error: "target_obscured", point, coveredBy: top ? (top.tagName || "").toLowerCase() : "" };
          };
          const boundsForTarget = (el) => {
            const rect = el.getBoundingClientRect();
            return {
              x: Math.round(rect.x),
              y: Math.round(rect.y),
              width: Math.round(rect.width),
              height: Math.round(rect.height)
            };
          };
          const publicTarget = (target) => {
            const el = target.el;
            if (!el) {
              const out = { ok: false, error: target.error || "target_not_found", locator: locatorSummary() };
              if (target.selector) out.selector = target.selector;
              if (target.point) out.point = target.point;
              if (target.coveredBy) out.coveredBy = target.coveredBy;
              return out;
            }
            return {
              ok: target.ok,
              error: target.error || "",
              selector: selectorFor(el),
              requestedSelector: selector || "",
              label: labelFor(el),
              role: roleFor(el),
              tag: el.tagName.toLowerCase(),
              type: el.getAttribute("type") || "",
              disabled: disabled(el),
              visible: visible(el),
              actionable: target.ok,
              locator: locatorSummary(),
              x: target.point?.x,
              y: target.point?.y,
              bounds: boundsForTarget(el),
              normalized: Boolean(target.point?.normalized),
              coveredBy: target.coveredBy || "",
              url: location.href
            };
          };
          const resolveTarget = () => {
            let point = hasPoint ? pointFrom(rawX, rawY) : null;
            let el = null;
            if (selector) {
              try { el = document.querySelector(selector); } catch (_) { return { ok: false, error: "invalid_selector", selector }; }
            }
            if (!el && point) el = document.elementFromPoint(point.x, point.y);
            if (!el && (locatorLabel || locatorRole || locatorText || locatorPlaceholder || locatorTestID)) {
              const candidates = allControls().filter(matchesLocator).sort((a, b) => scoreFor(b) - scoreFor(a));
              el = candidates[0] || null;
            }
            if (!el) return { ok: false, error: selector ? "selector_not_found" : "target_not_found", selector, point };
            if (!visible(el)) return { ok: false, error: "target_not_visible", el, point };
            if (disabled(el)) return { ok: false, error: "target_disabled", el, point };
            const actionability = actionablePoint(el, point);
            if (!actionability.ok) return { ok: false, error: actionability.error, el, point: actionability.point, coveredBy: actionability.coveredBy };
            const targetLabel = labelFor(el);
            const type = String(el.getAttribute("type") || "").toLowerCase();
            const dangerous = /\\b(send|submit|delete|remove|purchase|pay|confirm|authorize|approve|place order|reply|reply all|forward|archive|move|mark read|mark as read|mark unread|mark as unread|junk|report junk|phishing|report phishing|discard)\\b/i.test(targetLabel) || type === "submit";
            if (dangerous && !allowDangerous) {
              return { ok: false, error: "confirmation_required", needsConfirmation: true, el, point: actionability.point };
            }
            return { ok: true, el, point: actionability.point };
          };
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

    private static func jsStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8),
              array.hasPrefix("["),
              array.hasSuffix("]") else {
            return #""""#
        }
        return String(array.dropFirst().dropLast())
    }
}
