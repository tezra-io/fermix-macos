// The Fermix page script: reads a page as Chrome's accessibility tree lists it,
// and resolves the refs it hands out back to the page's nodes for actions.
//
// It runs in the app's own content world, which the page cannot see or change,
// and installs itself once per document as `globalThis.__fermixPage`. Every
// call from the app carries this whole file ahead of the call, so a document
// the tab navigated to is served without a separate install step.
//
// The node list is the engine's renderer input (`browser/snapshot.ex`): a role,
// a name, the `editable`, `settable` and `url` properties, child ids, and a ref
// on every node an action can reach. Roles follow HTML-AAM with the explicit
// `role` first, names follow accname, and Chrome's own choices are mirrored
// where the renderer would print something different without them.
(() => {
  "use strict";
  if (globalThis.__fermixPage) return;

  const ELEMENT = 1;
  const TEXT = 3;

  // The renderer's three role sets, as `snapshot.ex` spells them.
  const INTERACTIVE = new Set(["button", "link", "textbox", "checkbox", "radio", "combobox", "listbox",
    "option", "searchbox", "slider", "spinbutton", "switch", "tab", "treeitem", "menuitem"]);
  const CONTENT = new Set(["heading", "cell", "gridcell", "columnheader", "rowheader", "listitem", "article",
    "region", "main", "navigation", "text", "StaticText", "paragraph"]);
  const STRUCTURAL = new Set(["generic", "group", "list", "table", "row", "rowgroup", "grid", "document",
    "RootWebArea", "WebArea", "none", "presentation"]);

  // ---------------------------------------------------------------- registry

  // Refs are integers held here, in the app's world, so the page can neither
  // read nor forge them. One node keeps one key for as long as it lives, which
  // makes a ref stable across snapshots of the same page.
  const registry = { keys: new WeakMap(), nodes: new Map(), next: 1 };

  function keyFor(node) {
    let key = registry.keys.get(node);
    if (key === undefined) {
      key = registry.next++;
      registry.keys.set(node, key);
      registry.nodes.set(key, new WeakRef(node));
    }
    return key;
  }

  function nodeFor(key) {
    const node = registry.nodes.get(key)?.deref();
    return node && node.isConnected ? node : null;
  }

  // Keys whose node is gone are dropped once they outnumber the live ones.
  function sweep(live) {
    if (registry.nodes.size < 4 * live + 1024) return;
    for (const [key, ref] of registry.nodes) {
      const node = ref.deref();
      if (!node || !node.isConnected) registry.nodes.delete(key);
    }
  }

  // ------------------------------------------------------------------ styles

  // One computed style per element per snapshot: the walk, the names and the
  // table heuristics all read the same elements.
  let styles = new Map();

  function style(element) {
    let computed = styles.get(element);
    if (!computed) {
      computed = element.ownerDocument.defaultView.getComputedStyle(element);
      styles.set(element, computed);
    }
    return computed;
  }

  const NEVER = new Set(["script", "style", "template", "head", "meta", "link", "title", "base", "noscript"]);
  const NO_PSEUDO = new Set(["input", "select", "textarea", "img", "br", "hr", "iframe", "video", "audio",
    "canvas", "svg", "option", "optgroup", "object", "embed"]);

  // A subtree the tree leaves out entirely. Zero-size and transparent elements
  // stay, as Chrome keeps them.
  let modal = null;

  function excluded(element) {
    if (NEVER.has(element.localName)) return true;
    if (modal && !element.contains(modal) && !modal.contains(element)) return true;
    if (element.getAttribute("aria-hidden") === "true") return true;
    if (element.hasAttribute("inert")) return true;
    if (element.hasAttribute("hidden") && element instanceof element.ownerDocument.defaultView.HTMLElement) return true;
    return style(element).display === "none";
  }

  function shown(element) {
    return style(element).visibility === "visible";
  }

  // ------------------------------------------------------------------- text

  const BLOCK = new Set(["block", "flex", "grid", "list-item", "table", "flow-root", "table-row",
    "table-cell", "table-caption"]);

  function collapse(text) {
    return text.replace(/ /g, " ").replace(/[\t\n\r\f ]+/g, " ");
  }

  function transform(text, element) {
    switch (element ? style(element).textTransform : "none") {
      case "uppercase": return text.toUpperCase();
      case "lowercase": return text.toLowerCase();
      case "capitalize": return text.replace(/(^|\s)(\S)/g, (_, space, letter) => space + letter.toUpperCase());
      default: return text;
    }
  }

  function textParent(textNode) {
    return textNode.parentElement ?? textNode.parentNode?.host ?? null;
  }

  function textOf(textNode) {
    return transform(collapse(textNode.data), textParent(textNode));
  }

  // CSS `content`, with the alternative text after a slash when there is one.
  let pseudos = new Map();

  function pseudoText(element, which) {
    if (NO_PSEUDO.has(element.localName)) return "";
    const key = which === "::before" ? 0 : 1;
    let pair = pseudos.get(element);
    if (!pair) {
      pair = [null, null];
      pseudos.set(element, pair);
    }
    if (pair[key] === null) pair[key] = readPseudo(element, which);
    return pair[key];
  }

  function readPseudo(element, which) {
    const content = element.ownerDocument.defaultView.getComputedStyle(element, which).content;
    if (!content || content === "none" || content === "normal") return "";
    const main = [];
    let alt = null;
    const tokens = /"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|attr\(\s*([^)\s]+)\s*\)|\/|[a-z-]+\([^)]*\)|[a-z-]+/gi;
    for (const token of content.matchAll(tokens)) {
      if (token[0] === "/") { alt = []; continue; }
      const into = alt ?? main;
      if (token[1] !== undefined || token[2] !== undefined) into.push(unescapeCss(token[1] ?? token[2]));
      else if (token[3] !== undefined) into.push(element.getAttribute(token[3]) ?? "");
    }
    return collapse((alt ?? main).join(""));
  }

  function unescapeCss(text) {
    return text.replace(/\\([0-9a-fA-F]{1,6})\s?|\\(.)/g,
      (_, hex, char) => (hex ? String.fromCodePoint(parseInt(hex, 16)) : char));
  }

  // -------------------------------------------------------------- flat tree

  // Children as the page renders them: a shadow root's in place of the light
  // ones, a slot's assigned nodes (or its fallback), and a same-origin
  // frame's document.
  function childrenOf(node) {
    if (node.nodeType === ELEMENT) {
      if (node.shadowRoot) return node.shadowRoot.childNodes;
      if (node.localName === "slot") {
        const assigned = node.assignedNodes();
        return assigned.length ? assigned : node.childNodes;
      }
    }
    return node.childNodes;
  }

  // --------------------------------------------------------------------- roles

  const ARIA_ROLES = new Set(["alert", "alertdialog", "application", "article", "banner", "blockquote",
    "button", "caption", "cell", "checkbox", "code", "columnheader", "combobox", "comment", "complementary",
    "contentinfo", "definition", "deletion", "dialog", "directory", "document", "emphasis", "feed", "figure",
    "form", "generic", "grid", "gridcell", "group", "heading", "img", "image", "insertion", "link", "list",
    "listbox", "listitem", "log", "main", "mark", "marquee", "math", "menu", "menubar", "menuitem",
    "menuitemcheckbox", "menuitemradio", "meter", "navigation", "none", "note", "option", "paragraph",
    "presentation", "progressbar", "radio", "radiogroup", "region", "row", "rowgroup", "rowheader",
    "scrollbar", "search", "searchbox", "separator", "slider", "spinbutton", "status", "strong",
    "subscript", "superscript", "switch", "tab", "table", "tablist", "tabpanel", "term", "textbox", "time",
    "timer", "toolbar", "tooltip", "tree", "treegrid", "treeitem"]);

  // Chrome's spelling of an ARIA role where it differs from ARIA's.
  const CHROME_ROLE = { img: "image", presentation: "none", directory: "list" };

  const TEXT_INPUTS = new Set(["text", "password", "email", "tel", "url", "search", "number", ""]);
  const INPUT_ROLE = {
    button: "button", submit: "button", reset: "button", image: "button", file: "button",
    checkbox: "checkbox", radio: "radio", range: "slider", color: "ColorWell", number: "spinbutton",
    search: "searchbox", date: "Date", "datetime-local": "DateTime", month: "DateTime", week: "DateTime",
    time: "InputTime"
  };

  function inputType(element) {
    return (element.getAttribute("type") || "").toLowerCase();
  }

  function isTextField(element) {
    return element.localName === "textarea"
      || (element.localName === "input" && (TEXT_INPUTS.has(inputType(element)) || !(inputType(element) in INPUT_ROLE)));
  }

  function explicitRole(element) {
    const tokens = (element.getAttribute("role") || "").trim().toLowerCase().split(/\s+/);
    const role = tokens.find((token) => ARIA_ROLES.has(token));
    if (!role) return null;
    if ((role === "none" || role === "presentation") && focusable(element)) return null;
    if (role === "separator" && focusable(element)) return "splitter";
    return CHROME_ROLE[role] ?? role;
  }

  function focusable(element) {
    return element.hasAttribute("tabindex") || element.isContentEditable
      || (/^(a|area)$/.test(element.localName) && element.hasAttribute("href"))
      || (/^(button|input|select|textarea)$/.test(element.localName) && !element.disabled);
  }

  // `header` and `footer` are landmarks only outside sectioning content.
  function scoped(element) {
    return !!element.parentElement?.closest("article, aside, main, nav, section");
  }

  function nativeRole(element, context) {
    const tag = element.localName;
    switch (tag) {
      case "a": case "area": return element.hasAttribute("href") ? "link" : "generic";
      case "article": return "article";
      case "aside": return "complementary";
      case "nav": return "navigation";
      case "main": return "main";
      case "header": return scoped(element) ? "generic" : "banner";
      case "footer": return scoped(element) ? "generic" : "contentinfo";
      case "section": return "section";
      case "form": return "form";
      case "search": return "search";
      case "h1": case "h2": case "h3": case "h4": case "h5": case "h6": return "heading";
      case "p": return "paragraph";
      case "ul": case "ol": case "menu": return "list";
      case "li": return context.inList ? "listitem" : "generic";
      case "dl": return "DescriptionList";
      case "dt": return "term";
      case "dd": return "definition";
      case "table": return tableKind(element) === "data" ? "table" : "LayoutTable";
      case "caption": return "caption";
      case "thead": case "tfoot": return context.table === "data" ? "rowgroup" : "none";
      case "tbody": return "none";
      case "tr": return context.table === "data" ? "row" : "LayoutTableRow";
      case "td": return context.table === "data" ? (context.grid ? "gridcell" : "cell") : "LayoutTableCell";
      case "th": return context.table === "data" ? headerRole(element) : "LayoutTableCell";
      case "button": return "button";
      case "input": return INPUT_ROLE[inputType(element)] ?? "textbox";
      case "select": return element.multiple || element.size > 1 ? "listbox" : "combobox";
      case "option": return "option";
      case "optgroup": return "group";
      case "textarea": return "textbox";
      case "img": return element.getAttribute("alt") === "" ? "none" : "image";
      case "svg": return "image";
      case "figure": return "figure";
      case "figcaption": return "Figcaption";
      case "details": return "group";
      case "summary": return element.parentElement?.localName === "details" ? "DisclosureTriangle" : "generic";
      case "dialog": return "dialog";
      case "fieldset": return "group";
      case "legend": return "Legend";
      case "label": return isChoice(element.control) ? "none" : "LabelText";
      case "hr": return "separator";
      case "progress": return "progressbar";
      case "meter": return "meter";
      case "output": return "status";
      case "iframe": case "frame": return "Iframe";
      case "video": return "Video";
      case "audio": return "Audio";
      case "canvas": return "Canvas";
      case "code": return "code";
      case "strong": return "strong";
      case "em": return "emphasis";
      case "blockquote": return "blockquote";
      case "time": return "time";
      case "mark": return "mark";
      case "del": case "s": return "deletion";
      case "ins": return "insertion";
      case "sub": return "subscript";
      case "sup": return "superscript";
      case "abbr": return "Abbr";
      case "math": return "math";
      case "br": return "LineBreak";
      case "html": case "body": case "slot": return "none";
      default: return "generic";
    }
  }

  function headerRole(cell) {
    const scope = (cell.getAttribute("scope") || "").toLowerCase();
    if (scope === "row" || scope === "rowgroup") return "rowheader";
    if (scope === "col" || scope === "colgroup") return "columnheader";
    const row = cell.parentElement;
    const inHead = row?.parentElement?.localName === "thead";
    const allHeaders = row && Array.from(row.cells).every((each) => each.localName === "th");
    return inHead || allHeaders || cell.cellIndex !== 0 ? "columnheader" : "rowheader";
  }

  // Chrome's data-table test, in the part that decides real pages: explicit
  // markup says data, a grid of one row or one column says layout, and
  // otherwise bordered or header-carrying cells say data.
  const tableKinds = new WeakMap();

  function tableKind(table) {
    let kind = tableKinds.get(table);
    if (kind === undefined) {
      kind = measureTable(table);
      tableKinds.set(table, kind);
    }
    return kind;
  }

  function measureTable(table) {
    if (table.caption || table.tHead || table.tFoot || table.querySelector(":scope > colgroup, :scope > col")) return "data";
    if (table.hasAttribute("summary") || table.hasAttribute("rules")) return "data";
    const rows = Array.from(table.rows).filter((row) => row.closest("table") === table);
    const firstBodyColumns = rows[0]?.cells.length ?? 0;
    if ((rows.length >= 20 && firstBodyColumns >= 2) || rows.length >= 50) return "data";
    let cells = 0;
    let bordered = 0;
    for (const row of rows) {
      for (const cell of row.cells) {
        if (cell.localName === "th" || cell.hasAttribute("headers") || cell.hasAttribute("abbr")
          || cell.hasAttribute("axis") || cell.hasAttribute("scope")) return "data";
        if (!cell.textContent.trim()) continue;
        cells += 1;
        const cellStyle = style(cell);
        if (parseFloat(cellStyle.borderTopWidth) > 0 || parseFloat(cellStyle.borderBottomWidth) > 0
          || parseFloat(cellStyle.borderLeftWidth) > 0) bordered += 1;
      }
    }
    if (cells <= 1 || rows.length < 2 || firstBodyColumns < 2) return "layout";
    return bordered * 2 >= cells ? "data" : "layout";
  }

  // The role a node is listed with, or "none" for one the tree passes through.
  function roleOf(element, context) {
    if (context.presentational?.has(element.localName)) return "none";
    const role = explicitRole(element) ?? nativeRole(element, context);
    if (role === "section") return nameOf(element, "region") ? "region" : "generic";
    return role;
  }

  // ---------------------------------------------------------------------- names

  // The roles Chrome names from their content. Landmarks, images and
  // containers are named by a label or an alternative only.
  const NAME_FROM_CONTENT = new Set(["button", "link", "heading", "cell", "gridcell", "columnheader",
    "rowheader", "LayoutTableCell", "checkbox", "radio", "switch", "tab", "treeitem", "menuitem",
    "menuitemcheckbox", "menuitemradio", "option", "tooltip", "term", "DisclosureTriangle", "ListMarker"]);

  let names = new Map();

  function nameOf(element, role) {
    const cached = names.get(element);
    if (cached !== undefined) return cached;
    const name = computeName(element, role).trim();
    names.set(element, name);
    return name;
  }

  function computeName(element, role) {
    return labelledBy(element)
      || ariaLabel(element)
      || nativeName(element, role)
      || (NAME_FROM_CONTENT.has(role) ? collapse(contentText(element, element, false)) : "")
      || titleOf(element)
      || placeholderOf(element);
  }

  function labelledBy(element) {
    const ids = (element.getAttribute("aria-labelledby") || "").trim();
    if (!ids) return "";
    const root = element.getRootNode();
    const parts = ids.split(/\s+/).map((id) => root.getElementById?.(id) ?? element.ownerDocument.getElementById(id))
      .filter(Boolean)
      .map((target) => collapse(ariaLabel(target) || contentText(target, element, true)).trim());
    return parts.filter(Boolean).join(" ");
  }

  function ariaLabel(element) {
    return collapse(element.getAttribute("aria-label") || "").trim();
  }

  function titleOf(element) {
    return collapse(element.getAttribute("title") || "").trim();
  }

  function placeholderOf(element) {
    if (!isTextField(element)) return collapse(element.getAttribute("aria-placeholder") || "").trim();
    return collapse(element.getAttribute("placeholder") || element.getAttribute("aria-placeholder") || "").trim();
  }

  const LABELABLE = new Set(["input", "select", "textarea", "button", "meter", "output", "progress"]);

  function nativeName(element, role) {
    const tag = element.localName;
    if (tag === "input") return inputName(element);
    if (LABELABLE.has(tag)) {
      const labelled = labelsText(element);
      if (labelled) return labelled;
    }
    switch (tag) {
      case "img": case "area": return collapse(element.getAttribute("alt") || "").trim();
      case "svg": return collapse(element.querySelector(":scope > title")?.textContent || "").trim();
      case "fieldset": return legendText(element, "legend");
      case "table": return legendText(element, "caption");
      case "optgroup": return collapse(element.getAttribute("label") || "").trim();
      case "option": return collapse(element.getAttribute("label") || element.text || "").trim();
      case "iframe": case "frame": return titleOf(element);
      default: return "";
    }
  }

  function inputName(input) {
    const type = inputType(input);
    const labelled = labelsText(input);
    if (labelled) return labelled;
    if (type === "button" || type === "submit" || type === "reset") return buttonValue(input);
    if (type === "image") return collapse(input.getAttribute("alt") || input.getAttribute("value") || "").trim()
      || titleOf(input) || "Submit";
    return "";
  }

  function buttonValue(input) {
    const value = input.getAttribute("value");
    if (value !== null) return collapse(value).trim();
    const type = inputType(input);
    return type === "submit" ? "Submit" : type === "reset" ? "Reset" : "";
  }

  function labelsText(control) {
    const labels = control.labels ? Array.from(control.labels) : [];
    return labels.map((label) => collapse(ariaLabel(label) || contentText(label, control, false)).trim())
      .filter(Boolean).join(" ");
  }

  function legendText(element, tag) {
    const legend = Array.from(element.children).find((child) => child.localName === tag);
    return legend ? collapse(contentText(legend, element, false)).trim() : "";
  }

  // Name from content: the rendered text of the subtree, with alternatives for
  // images and embedded controls, block children set apart by spaces, and the
  // pseudo-elements' text in place.
  function contentText(element, root, throughLabelledBy) {
    const parts = [pseudoText(element, "::before")];
    for (const child of childrenOf(element)) {
      if (child.nodeType === TEXT) parts.push(textOf(child));
      else if (child.nodeType === ELEMENT) parts.push(descendantText(child, root, throughLabelledBy));
    }
    parts.push(pseudoText(element, "::after"));
    return parts.join("");
  }

  function descendantText(element, root, throughLabelledBy) {
    if (element === root) return "";
    if (!throughLabelledBy && (excluded(element) || !shown(element))) return "";
    if (NEVER.has(element.localName)) return "";
    const tag = element.localName;
    if (tag === "br" || tag === "wbr") return " ";
    if (tag === "table" && tableKind(element) === "data") return "";
    if (element.getAttribute("role") === "group" && root.getAttribute?.("role") === "treeitem") return "";
    const text = embeddedValue(element) ?? alternativeText(element, root, throughLabelledBy);
    return BLOCK.has(style(element).display) ? ` ${text} ` : text;
  }

  function embeddedValue(element) {
    const tag = element.localName;
    if (isTextField(element) && (tag === "input" || tag === "textarea")) return fieldText(element);
    if (tag === "select") {
      return Array.from(element.selectedOptions).map((option) => option.label || option.text).join(" ");
    }
    if (tag === "input" && inputType(element) === "range") return element.value;
    return null;
  }

  function alternativeText(element, root, throughLabelledBy) {
    const text = (!throughLabelledBy && labelledBy(element)) || ariaLabel(element)
      || (element.localName === "input" ? inputName(element) : "")
      || nativeAlternative(element)
      || contentText(element, root, throughLabelledBy);
    return text.trim() ? text : titleOf(element) || text;
  }

  function nativeAlternative(element) {
    switch (element.localName) {
      case "img": case "area": return collapse(element.getAttribute("alt") || "");
      case "svg": return collapse(element.querySelector(":scope > title")?.textContent || "");
      default: return "";
    }
  }

  // ----------------------------------------------------------------- the walk

  // What a node passes down to its children.
  const ROOT_CONTEXT = Object.freeze({ inList: false, table: null, grid: false, presentational: null,
    editable: null, dropText: false, depth: 0 });

  const TABLE_PARTS = new Set(["thead", "tbody", "tfoot", "tr", "td", "th"]);

  class Walk {
    constructor(options) {
      this.nodes = [];
      this.interactive = options.mode === "interactive";
      this.depth = options.depth;
      this.budget = options.maxChars;
      this.spent = 0;
      this.elements = 0;
      this.refs = 0;
      this.crossOriginFrames = 0;
    }

    // A node the renderer will print in this mode, by its own rules: compact
    // skips unnamed structure, and interactive keeps only what matters.
    prints(node) {
      if (STRUCTURAL.has(node.role) && !node.name) return false;
      if (!this.interactive) return true;
      return INTERACTIVE.has(node.role) || CONTENT.has(node.role) || !!node.properties?.editable
        || node.properties?.settable === true;
    }

    // Adds a node under `parent` and answers the parent its children attach to:
    // the node itself, or the parent again when the node is dropped in
    // interactive mode because the renderer would pass through it.
    add(parent, context, fields) {
      const node = { id: this.nodes.length, role: fields.role, name: fields.name || "", childIds: [] };
      if (fields.value) node.value = fields.value;
      if (fields.properties) node.properties = fields.properties;
      if (fields.ref !== undefined) {
        node.ref = fields.ref;
        this.refs += 1;
      }
      const printed = this.prints(node);
      if (this.interactive && !printed) return { parent, depth: context.depth };
      if (context.depth >= this.depth || this.spent > this.budget) return null;
      this.nodes.push(node);
      parent.childIds.push(node.id);
      if (printed) this.spent += node.role.length + node.name.length + 4;
      return { parent: node, depth: context.depth + (printed ? 1 : 0) };
    }

    text(parent, context, text, fields = {}) {
      const name = text.trim();
      if (!name) return null;
      return this.add(parent, context, { role: "StaticText", name, ...fields });
    }

    children(node, parent, context) {
      for (const child of childrenOf(node)) this.visit(child, parent, context);
    }

    visit(node, parent, context) {
      if (this.spent > this.budget) return;
      if (node.nodeType === TEXT) return this.visitText(node, parent, context);
      if (node.nodeType !== ELEMENT || excluded(node)) return;
      this.elements += 1;
      if (!shown(node)) return this.children(node, parent, this.inherit(node, "none", context));
      const role = roleOf(node, context);
      const inner = this.inherit(node, role, context);
      const special = SPECIAL.get(node.localName);
      if (special) return special.call(this, node, role, parent, context, inner);
      const placed = this.place(node, role, parent, context);
      if (!placed) return;
      this.decorated(node, role, placed.parent, { ...inner, depth: placed.depth });
    }

    visitText(node, parent, context) {
      const owner = textParent(node);
      if (context.dropText || !owner || !shown(owner)) return;
      if (context.editable) return this.editableText(parent, context, textOf(node), keyFor(node), context.editable);
      this.text(parent, context, textOf(node));
    }

    // Editable text is a static text that reaches its node, over Chrome's
    // inline text box, which prints in interactive mode because it is editable.
    editableText(parent, context, text, key, editable) {
      const properties = { editable };
      const placed = this.text(parent, context, text, { properties, ref: key });
      if (placed) this.add(placed.parent, { ...context, depth: placed.depth }, { role: "InlineTextBox", name: text.trim(), properties });
    }

    // The element's own node, when it has one worth listing.
    place(element, role, parent, context) {
      const editable = context.editable || (element.isContentEditable ? "richtext" : null);
      if (role === "none") return { parent, depth: context.depth };
      const name = role === "generic" || role === "none" ? genericName(element) : nameOf(element, role);
      const properties = propertiesOf(element, role, editable);
      const actionable = INTERACTIVE.has(role) || !!properties?.editable || properties?.settable === true;
      if (role === "generic" && !name && !properties && !element.hasAttribute("tabindex")) {
        return { parent, depth: context.depth };
      }
      const fields = { role, name, properties };
      if (actionable) fields.ref = keyFor(element);
      return this.add(parent, context, fields);
    }

    // Pseudo-elements and list markers around the element's own children.
    // Generated text is the element's own text, so a checkbox's label drops it
    // with the rest.
    decorated(element, role, parent, context) {
      this.marker(element, role, parent, context);
      if (!context.dropText) this.text(parent, context, pseudoText(element, "::before"));
      this.children(element, parent, context);
      if (!context.dropText) this.text(parent, context, pseudoText(element, "::after"));
    }

    marker(element, role, parent, context) {
      const text = markerText(element);
      if (!text) return;
      if (role === "listitem") this.add(parent, context, { role: "ListMarker", name: text });
      else this.text(parent, context, text);
    }

    inherit(element, role, context) {
      const tag = element.localName;
      const next = { ...context };
      next.inList = role === "list" && context.presentational === null;
      if (role === "none" && /^(ul|ol|menu)$/.test(tag) && element.hasAttribute("role")) {
        next.presentational = new Set(["li"]);
      } else if (role === "none" && tag === "table" && element.hasAttribute("role")) {
        next.presentational = TABLE_PARTS;
      } else if (!(context.presentational === TABLE_PARTS && /^(thead|tbody|tfoot|tr)$/.test(tag))) {
        next.presentational = null;
      }
      if (tag === "table") {
        next.table = role === "none" ? null : tableKind(element);
        next.grid = role === "grid" || role === "treegrid";
      } else if (tag === "td" || tag === "th") {
        next.table = null;
      }
      if (element.isContentEditable && !context.editable) next.editable = "richtext";
      next.dropText = tag === "label" && isChoice(element.control);
      return next;
    }

    // A same-origin frame's document is listed under its frame; a
    // cross-origin one is flagged, because its content is out of reach.
    frame(element, role, parent, context) {
      const placed = this.place(element, role, parent, context);
      if (!placed) return;
      const document = element.contentDocument;
      if (!document) {
        this.crossOriginFrames += 1;
        if (placed.parent !== parent) placed.parent.properties = { ...placed.parent.properties, cross_origin: true };
        return;
      }
      if (document.documentElement) {
        this.children(document.documentElement, placed.parent, { ...ROOT_CONTEXT, depth: placed.depth });
      }
    }

    // A text field lists its value the way Chrome does: an editable generic
    // holding an editable static text, both reaching the field itself.
    textField(element, role, parent, context) {
      const placed = this.place(element, role, parent, context);
      if (!placed || !element.value) return;
      const key = keyFor(element);
      const properties = { editable: "plaintext" };
      const inner = this.add(placed.parent, { ...context, depth: placed.depth },
        { role: "generic", properties, ref: key });
      if (!inner) return;
      this.editableText(inner.parent, { ...context, depth: inner.depth }, collapse(fieldText(element)), key, "plaintext");
    }

    // An input button shows its label as a static text child.
    inputButton(element, role, parent, context) {
      const placed = this.place(element, role, parent, context);
      if (!placed) return;
      const type = inputType(element);
      const at = { ...context, depth: placed.depth };
      if (type === "image") this.add(placed.parent, at, { role: "image" });
      if (type === "button" || type === "submit" || type === "reset" || type === "image") {
        this.text(placed.parent, at, nameOf(element, role));
      }
    }

    select(element, role, parent, context) {
      const placed = this.place(element, role, parent, context);
      if (!placed) return;
      let at = { ...context, depth: placed.depth };
      let holder = placed.parent;
      if (role === "combobox") {
        const popup = this.add(holder, at, { role: "MenuListPopup" });
        if (!popup) return;
        holder = popup.parent;
        at = { ...at, depth: popup.depth };
      }
      this.options(element, holder, at);
    }

    options(container, parent, context) {
      for (const child of container.children) {
        if (child.localName === "option" && !child.hidden) {
          this.add(parent, context, { role: "option", name: nameOf(child, "option"), ref: keyFor(child) });
        } else if (child.localName === "optgroup") {
          const group = this.add(parent, context, { role: "group", name: nameOf(child, "group") });
          if (group) this.options(child, group.parent, { ...context, depth: group.depth });
        }
      }
    }

    // A closed `details` lists its summary alone.
    details(element, role, parent, context, inner) {
      const placed = this.place(element, role, parent, context);
      if (!placed) return;
      const at = { ...inner, depth: placed.depth };
      if (element.open) return this.children(element, placed.parent, at);
      const summary = Array.from(element.children).find((child) => child.localName === "summary");
      if (summary) this.visit(summary, placed.parent, at);
    }

    leaf(element, role, parent, context) {
      this.place(element, role, parent, context);
    }
  }

  function input(element, role, parent, context, inner) {
    if (inputType(element) === "hidden") return;
    if (isTextField(element)) return this.textField(element, role, parent, context);
    return this.inputButton(element, role, parent, context, inner);
  }

  // Elements whose children Chrome lists its own way, or not at all.
  const SPECIAL = new Map([
    ["input", input],
    ["textarea", Walk.prototype.textField],
    ["select", Walk.prototype.select],
    ["iframe", Walk.prototype.frame],
    ["frame", Walk.prototype.frame],
    ["details", Walk.prototype.details],
    ...["img", "svg", "hr", "br", "video", "audio", "object", "embed", "progress", "meter"]
      .map((tag) => [tag, Walk.prototype.leaf])
  ]);

  function isChoice(control) {
    return !!control && control.localName === "input" && /^(checkbox|radio)$/.test(inputType(control));
  }

  function genericName(element) {
    return labelledBy(element) || ariaLabel(element) || titleOf(element);
  }

  function propertiesOf(element, role, editable) {
    const properties = {};
    if (element.localName === "input" || element.localName === "textarea") {
      if (isTextField(element)) {
        properties.editable = "plaintext";
        properties.settable = true;
      } else if (/^(range|color|date|datetime-local|month|week|time)$/.test(inputType(element))) {
        properties.settable = true;
      }
    } else if (editable) {
      properties.editable = editable;
      if (role === "textbox" || role === "searchbox") properties.settable = true;
    } else if (/^(slider|spinbutton|searchbox|textbox|separator|splitter|scrollbar)$/.test(role)) {
      properties.settable = true;
    }
    const url = urlOf(element, role);
    if (url) properties.url = url;
    return Object.keys(properties).length ? properties : undefined;
  }

  function urlOf(element, role) {
    if (role === "link" && element.href) return String(element.href);
    if (element.localName === "img") return element.currentSrc || element.src || "";
    if (element.localName === "input" && inputType(element) === "image") return element.src || "";
    return "";
  }

  const MARKERS = {
    disc: () => "• ", circle: () => "◦ ", square: () => "▪ ",
    decimal: (n) => `${n}. `,
    "decimal-leading-zero": (n) => `${String(n).padStart(2, "0")}. `,
    "lower-alpha": (n) => `${alphabetic(n)}. `, "lower-latin": (n) => `${alphabetic(n)}. `,
    "upper-alpha": (n) => `${alphabetic(n).toUpperCase()}. `, "upper-latin": (n) => `${alphabetic(n).toUpperCase()}. `,
    "lower-roman": (n) => `${roman(n)}. `, "upper-roman": (n) => `${roman(n).toUpperCase()}. `
  };

  function markerText(element) {
    if (element.localName !== "li") return "";
    const itemStyle = style(element);
    if (itemStyle.display !== "list-item") return "";
    const format = MARKERS[itemStyle.listStyleType];
    return format ? format(ordinal(element)) : "";
  }

  function ordinal(item) {
    if (item.hasAttribute("value")) return item.value;
    const list = item.parentElement;
    const start = list?.localName === "ol" ? list.start : 1;
    let index = 0;
    for (let sibling = item.previousElementSibling; sibling; sibling = sibling.previousElementSibling) {
      if (sibling.localName === "li") index += 1;
    }
    return start + index;
  }

  function alphabetic(n) {
    let text = "";
    for (let value = n; value > 0; value = Math.floor((value - 1) / 26)) {
      text = String.fromCharCode(97 + ((value - 1) % 26)) + text;
    }
    return text;
  }

  function roman(n) {
    const table = [[1000, "m"], [900, "cm"], [500, "d"], [400, "cd"], [100, "c"], [90, "xc"], [50, "l"],
      [40, "xl"], [10, "x"], [9, "ix"], [5, "v"], [4, "iv"], [1, "i"]];
    let text = "";
    let value = n;
    for (const [amount, letters] of table) {
      while (value >= amount) { text += letters; value -= amount; }
    }
    return text;
  }

  // ------------------------------------------------------------------ snapshot

  // The per-snapshot caches, emptied so a page never answers from a stale one.
  function reset() {
    styles = new Map();
    names = new Map();
    pseudos = new Map();
    modal = null;
  }

  function snapshot(options) {
    reset();
    modal = document.querySelector("dialog:modal");
    const walk = new Walk(options);
    const root = { id: 0, role: "RootWebArea", name: collapse(document.title).trim(), childIds: [],
      properties: { url: location.href } };
    walk.nodes.push(root);
    const depth = walk.prints(root) ? 1 : 0;
    if (document.documentElement) walk.children(document.documentElement, root, { ...ROOT_CONTEXT, depth });
    sweep(walk.refs);
    reset();
    // A plain object, exactly as every other function here answers: the one
    // call that reaches this file (`WebKitPageScript.text`) does the whole
    // answer's JSON.stringify itself, once, so a second one here would hand
    // the app a string where it expects the object.
    return {
      title: document.title,
      url: location.href,
      nodes: walk.nodes,
      elements: walk.elements,
      crossOriginFrames: walk.crossOriginFrames,
      closedShadowRoots: options.closedShadowRoots
    };
  }

  // ------------------------------------------------------------------- actions

  // Where a ref's node is, in the top document's layout viewport, once it is
  // on screen: frames add their own offsets, a text node answers with its
  // range. `viewport` is the top window's visual viewport, which the app
  // needs to place the box in the web view when the page is pinch-zoomed.
  function locate(key) {
    const node = nodeFor(key);
    if (!node) return { error: "stale" };
    const element = node.nodeType === TEXT ? node.parentElement : node;
    if (element.scrollIntoViewIfNeeded) element.scrollIntoViewIfNeeded(true);
    else element.scrollIntoView({ block: "center", inline: "center" });
    const rects = node.nodeType === TEXT ? rangeRects(node) : element.getClientRects();
    if (!rects.length) return { error: "no_box" };
    const box = node.nodeType === TEXT ? rects[0] : element.getBoundingClientRect();
    const offset = frameOffset(element.ownerDocument.defaultView);
    return { x: box.left + offset.x, y: box.top + offset.y, width: box.width, height: box.height, viewport: viewportInfo() };
  }

  // The top window's visual viewport, for a point given with no ref
  // (`click_coords`) and for a ref's box.
  function viewportInfo() {
    const visual = window.visualViewport;
    return visual
      ? { offsetLeft: visual.offsetLeft, offsetTop: visual.offsetTop, scale: visual.scale }
      : { offsetLeft: 0, offsetTop: 0, scale: 1 };
  }

  function rangeRects(textNode) {
    const range = textNode.ownerDocument.createRange();
    range.selectNodeContents(textNode);
    return range.getClientRects();
  }

  function frameOffset(view) {
    let x = 0;
    let y = 0;
    for (let frameView = view; frameView.frameElement; frameView = frameView.parent) {
      const frame = frameView.frameElement;
      const box = frame.getBoundingClientRect();
      const frameStyle = frameView.parent.getComputedStyle(frame);
      x += box.left + frame.clientLeft + parseFloat(frameStyle.paddingLeft);
      y += box.top + frame.clientTop + parseFloat(frameStyle.paddingTop);
    }
    return { x, y };
  }

  // The element a typed value lands in: the field, or the editing host of an
  // editable text node.
  function field(key) {
    const node = nodeFor(key);
    if (!node) return null;
    if (node.nodeType === TEXT) return node.parentElement?.closest("[contenteditable]") ?? null;
    return node;
  }

  // After a trusted click has focused the field, select what it holds so the
  // typed keys replace it, or put the caret at its end so they append.
  function prepareTyping(key, append) {
    const element = field(key);
    if (!element) return { error: "stale" };
    if ("setSelectionRange" in element && typeof element.value === "string") {
      try {
        const end = element.value.length;
        element.setSelectionRange(append ? end : 0, end);
      } catch {
        element.select?.();
      }
      return { value: readValue(element) };
    }
    if (element.isContentEditable) {
      const selection = element.ownerDocument.getSelection();
      const range = element.ownerDocument.createRange();
      range.selectNodeContents(element);
      if (append) range.collapse(false);
      selection.removeAllRanges();
      selection.addRange(range);
      return { value: element.textContent };
    }
    return { error: "not_editable" };
  }

  // A value set through the element's own setter, then announced as input and
  // change. The page sees `isTrusted` false on both events.
  function setValue(key, text, append) {
    const element = field(key);
    if (!element) return { error: "stale" };
    if (element.isContentEditable) {
      element.textContent = append ? element.textContent + text : text;
    } else if (typeof element.value === "string") {
      const prototype = Object.getPrototypeOf(element);
      const setter = Object.getOwnPropertyDescriptor(prototype, "value")?.set;
      const value = append ? element.value + text : text;
      if (setter) setter.call(element, value);
      else element.value = value;
    } else {
      return { error: "not_editable" };
    }
    announce(element, "input");
    announce(element, "change");
    return { value: readValue(element) };
  }

  function announce(element, type) {
    element.dispatchEvent(new Event(type, { bubbles: true }));
  }

  function readValue(element) {
    return element.isContentEditable ? element.textContent : fieldText(element);
  }

  // A field's value as every read of the page answers it: a password field's
  // as one bullet per character, the way the snapshot draws it, so no act,
  // name or snapshot ever carries what a password field holds.
  function fieldText(element) {
    return isPasswordField(element) ? "•".repeat(element.value.length) : element.value;
  }

  function isPasswordField(element) {
    return element.localName === "input" && inputType(element) === "password";
  }

  function valueOf(key) {
    const element = field(key);
    return element ? { value: readValue(element) } : { error: "stale" };
  }

  // A `select`'s option by value or label, announced as input and change.
  function selectOption(key, wanted) {
    const element = nodeFor(key);
    if (!element) return { error: "stale" };
    const select = element.localName === "option" ? element.closest("select") : element;
    if (!select || select.localName !== "select") return { error: "not_select" };
    const option = Array.from(select.options).find((each) => each.value === wanted)
      ?? Array.from(select.options).find((each) => collapse(each.label || each.text).trim() === wanted);
    if (!option) return { error: "no_option" };
    option.selected = true;
    announce(select, "input");
    announce(select, "change");
    return { value: option.value, label: collapse(option.label || option.text).trim() };
  }

  // The engine's submit: the form's primary control, clicked by the app as a
  // person would, or the form asked to submit itself when it has none.
  const SUBMIT_CONTROLS = ["button[type='submit']", "input[type='submit']", "[role='search'] button",
    "button:not([type])", "button"];

  function submitControl(key) {
    const element = field(key) ?? nodeFor(key);
    if (!element) return { error: "stale" };
    const form = element.form || element.closest?.("form") || element.ownerDocument.forms[0];
    if (!form) return { error: "no_form" };
    for (const selector of SUBMIT_CONTROLS) {
      const control = form.querySelector(selector);
      if (control) {
        const label = collapse(control.innerText || control.value || selector).trim().slice(0, 80);
        return { ref: keyFor(control), label };
      }
    }
    form.requestSubmit();
    return { label: "form.requestSubmit()" };
  }

  function scrollBy(key, dx, dy) {
    const node = key === null ? null : nodeFor(key);
    if (key !== null && !node) return { error: "stale" };
    const target = node ? (node.nodeType === TEXT ? node.parentElement : node) : null;
    if (target) target.scrollBy({ left: dx, top: dy });
    else window.scrollBy({ left: dx, top: dy });
    return { x: window.scrollX, y: window.scrollY };
  }

  // A file chooser, opened the way the page's own button would open it. The
  // app answers the chooser with the path it was given.
  function openChooser(key) {
    const element = nodeFor(key);
    if (!element) return { error: "stale" };
    if (element.localName !== "input" || inputType(element) !== "file") return { error: "not_file_input" };
    element.click();
    return {};
  }

  function files(key) {
    const element = nodeFor(key);
    if (!element) return { error: "stale" };
    return { names: Array.from(element.files ?? []).map((file) => file.name) };
  }

  // What an action is judged by: where the page is, what it is called, how
  // much of it there is, and what holds the focus.
  function fingerprint() {
    let active = document.activeElement;
    while (active?.shadowRoot?.activeElement) active = active.shadowRoot.activeElement;
    return {
      url: location.href,
      title: document.title,
      elements: document.getElementsByTagName("*").length,
      text: document.body ? document.body.textContent.length : 0,
      focus: active && active !== document.body ? keyFor(active) : 0,
      ready: document.readyState
    };
  }

  // `act` `kind=get`: a read of the page, never an input. `selector`, where a
  // field takes it, scopes the read to its first match; the field's own
  // shape (a string, a count, or `rect`'s box) is what the app decodes.
  function get(field, selector) {
    switch (field) {
      case "text":
        return getText(selector);
      case "title":
        return { value: document.title };
      case "html":
        return getHtml(selector);
      case "ready_state":
        return { value: document.readyState };
      case "count":
        return { value: selector ? document.querySelectorAll(selector).length : document.getElementsByTagName("*").length };
      case "rect":
        return getRect(selector);
      default:
        return { error: "invalid_request" };
    }
  }

  function getText(selector) {
    if (!selector) return { value: collapse(document.body ? document.body.textContent : "").trim() };
    const element = document.querySelector(selector);
    return element ? { value: collapse(element.textContent || "").trim() } : { error: "no_box" };
  }

  function getHtml(selector) {
    if (!selector) return { value: document.documentElement ? serialized(document.documentElement) : "" };
    const element = document.querySelector(selector);
    return element ? { value: serialized(element) } : { error: "no_box" };
  }

  // The markup of a copy with no `value` attribute on any password field,
  // which frameworks such as React copy a controlled input's value into. The
  // copy is made in a document of its own, with no window, so none of the
  // page's custom elements is constructed for it.
  function serialized(element) {
    const copy = document.implementation.createHTMLDocument("").importNode(element, true);
    const inputs = copy.localName === "input" ? [copy] : Array.from(copy.querySelectorAll("input"));
    for (const input of inputs) {
      if (isPasswordField(input)) input.removeAttribute("value");
    }
    return copy.outerHTML;
  }

  function getRect(selector) {
    if (!selector) return { error: "invalid_request" };
    const element = document.querySelector(selector);
    if (!element) return { error: "no_box" };
    const box = element.getBoundingClientRect();
    return { value: { x: box.left, y: box.top, width: box.width, height: box.height } };
  }

  // `act` `kind=wait`: one look at whether the condition already holds. The
  // app polls this on its own bounded interval until it answers `done: true`
  // or its own timeout elapses; nothing here ever loops or blocks.
  function waitCondition(waitUntil, text, selector, ref) {
    switch (waitUntil) {
      case "load":
        return { done: document.readyState === "complete" };
      case "url":
        return { done: typeof text === "string" && location.href.includes(text) };
      case "text":
        return { done: typeof text === "string" && document.body != null && document.body.innerText.includes(text) };
      case "element":
        return { done: elementWaitedFor(selector, ref) };
      default:
        return { error: "invalid_request" };
    }
  }

  function elementWaitedFor(selector, ref) {
    if (selector) return document.querySelector(selector) != null;
    if (ref !== null && ref !== undefined) return nodeFor(ref) != null;
    return false;
  }

  // The document's own height, for a `page.screenshot` `full_page` capture:
  // the app asks WebKit for a snapshot as tall as this, which it renders
  // where it can and otherwise crops to the viewport it already had.
  function documentHeight() {
    const root = document.documentElement;
    return { value: root ? root.scrollHeight : window.innerHeight };
  }

  // ------------------------------------------------------------------- sign-in

  // A saved login typed into the page in one call (M84 §8): every check
  // before anything is set, then the values through each input's own setter,
  // username first. The page cannot come between the checks and the write,
  // because one script call runs to its end before the page runs again. The
  // answer is `{ok: true}` and nothing else: no value ever comes back.
  const USERNAME_TYPES = new Set(["", "text", "email", "tel"]);
  const filledPasswords = new WeakSet();
  const guardedRoots = new WeakSet();

  function fillLogin(request) {
    const fields = loginFields(request);
    if (fields.error) return fields;
    const origin = new URL(request.topURL).origin;
    if (originOf(document) !== origin) return { error: "moved", detail: "top" };
    if (fields.list.some(({ element }) => originOf(element.ownerDocument) !== origin)) {
      return { error: "moved", detail: "frame" };
    }
    for (const { element, key } of fields.list) {
      if (!keepsFocus(element)) return { error: "field", ref: key, detail: "focus" };
    }
    for (const { element } of fields.list) guardRootsOf(element);
    for (const { element, value } of fields.list) typeInto(element, value);
    if (fields.password) pinDots(fields.password);
    for (const { element } of fields.list) stripPasswordValues(element.getRootNode());
    return { ok: true };
  }

  // The refs resolved and their kinds checked: a password field for the
  // password, a plain text, email or phone input for the username, both in
  // one document. Username first, the order they are typed in.
  function loginFields(request) {
    const list = [];
    if (request.usernameRef !== null) {
      const element = nodeFor(request.usernameRef);
      if (!element) return { error: "stale", ref: request.usernameRef };
      if (element.localName !== "input" || !USERNAME_TYPES.has(inputType(element))) {
        return { error: "field", ref: request.usernameRef, detail: "username" };
      }
      list.push({ element, key: request.usernameRef, value: request.username });
    }
    let password = null;
    if (request.passwordRef !== null) {
      password = nodeFor(request.passwordRef);
      if (!password) return { error: "stale", ref: request.passwordRef };
      if (!isPasswordField(password)) return { error: "field", ref: request.passwordRef, detail: "password" };
      list.push({ element: password, key: request.passwordRef, value: request.password });
    }
    if (list.length === 2 && list[0].element.ownerDocument !== list[1].element.ownerDocument) {
      return { error: "field", detail: "documents" };
    }
    return { list, password };
  }

  // A document's own origin, as its window holds it: a frame the page wrote
  // itself carries its creator's origin, and a sandboxed one an opaque one.
  function originOf(doc) {
    return doc.defaultView ? doc.defaultView.origin : null;
  }

  // Whether the field takes the focus and still holds it once every focus
  // handler the page attached has run.
  function keepsFocus(element) {
    element.focus({ preventScroll: true });
    return element.getRootNode().activeElement === element;
  }

  function typeInto(element, value) {
    element.focus({ preventScroll: true });
    nativeSetValue(element, value);
    element.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
    element.dispatchEvent(new Event("change", { bubbles: true }));
    if (isPasswordField(element)) filledPasswords.add(element);
  }

  // The input's own value setter, from its own window's prototype: a value
  // set this way is the one a person's typing leaves.
  function nativeSetValue(element, value) {
    const prototype = element.ownerDocument.defaultView.HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(prototype, "value").set.call(element, value);
  }

  // The field's dots as an important inline style, which outranks any rule a
  // stylesheet or a class can bring.
  function pinDots(element) {
    const style = element.style;
    if (style.getPropertyValue("-webkit-text-security") === "disc"
      && style.getPropertyPriority("-webkit-text-security") === "important") return;
    style.setProperty("-webkit-text-security", "disc", "important");
  }

  function stripPasswordValues(root) {
    for (const input of root.querySelectorAll("input[value]")) {
      if (isPasswordField(input)) input.removeAttribute("value");
    }
  }

  // ------------------------------------------------------------ the guard

  // One guard per document and per shadow root holding a filled field,
  // installed once each: an observer that undoes every way a page reveals a
  // filled password through its attributes, and a capture-phase listener
  // that keeps a GET form from putting it in the address. Observer callbacks
  // run as microtasks, after the page's own change and before anything
  // renders or another script call reads the page.
  function guardRootsOf(element) {
    guardRoot(element.ownerDocument);
    const root = element.getRootNode();
    if (root !== element.ownerDocument) guardRoot(root);
  }

  function guardRoot(root) {
    if (guardedRoots.has(root)) return;
    guardedRoots.add(root);
    const view = (root.ownerDocument ?? root).defaultView;
    new view.MutationObserver(guardMutations).observe(root, {
      subtree: true, attributes: true, attributeOldValue: true, attributeFilter: ["type", "value", "style"]
    });
    root.addEventListener("submit", guardSubmit, true);
  }

  function guardMutations(records) {
    for (const record of records) {
      const element = record.target;
      if (element.localName !== "input") continue;
      if (record.attributeName === "type") clearRevealed(element, record.oldValue);
      else if (record.attributeName === "value" && isPasswordField(element)) element.removeAttribute("value");
      else if (record.attributeName === "style" && filledPasswords.has(element)) pinDots(element);
    }
  }

  // A field that stopped being a password field (a show-password button) is
  // emptied before it can render or be read as text.
  function clearRevealed(element, oldType) {
    if ((oldType || "").toLowerCase() !== "password" || isPasswordField(element)) return;
    nativeSetValue(element, "");
    element.removeAttribute("value");
    filledPasswords.delete(element);
  }

  // A submission that would send a filled password by GET loses its default
  // action, so the password never reaches an address. The page's own
  // handlers still run: most login forms send with `fetch` and cancel the
  // default themselves.
  function guardSubmit(event) {
    const form = event.target;
    if (!form || form.localName !== "form") return;
    const submitter = event.submitter;
    const method = submitter && submitter.hasAttribute("formmethod") ? submitter.formMethod : form.method;
    if (method !== "get") return;
    const sendsPassword = Array.from(form.elements).some((control) => filledPasswords.has(control) && control.value);
    if (sendsPassword) event.preventDefault();
  }

  // ------------------------------------------------------- the capture guard

  // Whether a filled password shows as text anywhere a capture would see it:
  // the value of every connected input and textarea that is not a password
  // field and whose length is one the app filled, hashed and compared with
  // the app's own digests. The passwords themselves never come here.
  const MAX_GUARDED_ROOTS = 1000;

  function secretOnScreen(lengths, digests) {
    const wantedLengths = new Set(lengths);
    const known = new Set(digests);
    const roots = [document];
    for (let index = 0; index < roots.length; index += 1) {
      if (roots.length > MAX_GUARDED_ROOTS) return { error: "too_large" };
      for (const element of roots[index].querySelectorAll("*")) {
        if (element.shadowRoot) roots.push(element.shadowRoot);
        if ((element.localName === "iframe" || element.localName === "frame") && element.contentDocument) {
          roots.push(element.contentDocument);
        }
        if (showsText(element, wantedLengths) && known.has(sha256Hex(element.value))) return { shown: true };
      }
    }
    return { shown: false };
  }

  function showsText(element, wantedLengths) {
    const tag = element.localName;
    if (tag !== "textarea" && (tag !== "input" || isPasswordField(element))) return false;
    return element.isConnected && wantedLengths.has(element.value.length);
  }

  // SHA-256 of a string's UTF-8 bytes, as lowercase hex (FIPS 180-4). The
  // script carries its own because `crypto.subtle` is asynchronous and absent
  // from a page that is not a secure context.
  const SHA256_K = new Uint32Array([
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  ]);

  function sha256Hex(text) {
    const bytes = new TextEncoder().encode(text);
    const padded = new Uint8Array((((bytes.length + 8) >> 6) + 1) << 6);
    padded.set(bytes);
    padded[bytes.length] = 0x80;
    const view = new DataView(padded.buffer);
    view.setUint32(padded.length - 8, Math.floor(bytes.length / 0x20000000));
    view.setUint32(padded.length - 4, (bytes.length * 8) >>> 0);
    const hash = new Uint32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
    const words = new Uint32Array(64);
    for (let offset = 0; offset < padded.length; offset += 64) sha256Block(view, offset, words, hash);
    return Array.from(hash, (word) => word.toString(16).padStart(8, "0")).join("");
  }

  function sha256Block(view, offset, words, hash) {
    const rotate = (value, by) => (value >>> by) | (value << (32 - by));
    for (let i = 0; i < 16; i += 1) words[i] = view.getUint32(offset + i * 4);
    for (let i = 16; i < 64; i += 1) {
      const s0 = rotate(words[i - 15], 7) ^ rotate(words[i - 15], 18) ^ (words[i - 15] >>> 3);
      const s1 = rotate(words[i - 2], 17) ^ rotate(words[i - 2], 19) ^ (words[i - 2] >>> 10);
      words[i] = (words[i - 16] + s0 + words[i - 7] + s1) >>> 0;
    }
    let [a, b, c, d, e, f, g, h] = hash;
    for (let i = 0; i < 64; i += 1) {
      const t1 = (h + (rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)) + ((e & f) ^ (~e & g)) + SHA256_K[i] + words[i]) >>> 0;
      const t2 = ((rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) >>> 0;
      [h, g, f, e, d, c, b, a] = [g, f, e, (d + t1) >>> 0, c, b, a, (t1 + t2) >>> 0];
    }
    const next = [a, b, c, d, e, f, g, h];
    for (let i = 0; i < 8; i += 1) hash[i] = (hash[i] + next[i]) >>> 0;
  }

  globalThis.__fermixPage = Object.freeze({
    snapshot, locate, viewport: viewportInfo, prepareTyping, setValue, valueOf, selectOption,
    submitControl, scrollBy, openChooser, files, fingerprint, get, waitCondition, documentHeight,
    fillLogin, secretOnScreen
  });
})();
