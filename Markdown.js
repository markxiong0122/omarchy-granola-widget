// Markdown → small controlled HTML for the note pane.
//
// TextEdit keeps raw hashes and gives every heading the same weight, so the
// note is turned into a fragment instead: quieter headings, real bullets,
// checkboxes, code and links. Escape first, then style — never the reverse.
.pragma library

function escapeHtml(text) {
  return String(text || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
}

function inlineMarkdown(text) {
  var out = String(text || "")
  out = out.replace(/`([^`]+)`/g, "<code>$1</code>")
  out = out.replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>")
  out = out.replace(/(^|[^\w])_([^_]+)_/g, "$1<i>$2</i>")
  out = out.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2">$1</a>')
  return out
}

function markdownHtml(markdown) {
  var lines = String(markdown || "").split("\n")
  var html = []
  var i = 0
  while (i < lines.length) {
    var raw = lines[i]
    var line = raw.trim()
    if (line === "") { i++; continue }

    // Fenced code: keep it verbatim, monospaced, and dim.
    if (/^```/.test(line)) {
      var code = []
      i++
      while (i < lines.length && !/^```/.test(lines[i].trim())) {
        code.push(escapeHtml(lines[i]))
        i++
      }
      html.push('<p><code>' + code.join("<br>") + '</code></p>')
      i++
      continue
    }

    var heading = line.match(/^(#{1,4})\s+(.*)$/)
    if (heading) {
      var size = ["4", "3", "3", "2"][heading[1].length - 1] || "3"
      if (html.length > 0) html.push("<br>")
      html.push('<p><font size="' + size + '"><b>'
        + inlineMarkdown(escapeHtml(heading[2]))
        + '</b></font></p>')
      i++
      continue
    }

    var bullet = raw.match(/^(\s*)[-*]\s+(.*)$/)
    if (bullet) {
      var depth = Math.min(3, Math.floor(bullet[1].length / 2))
      var pad = ""
      for (var d = 0; d < depth; d++) pad += "&nbsp;&nbsp;&nbsp;&nbsp;"
      var body = bullet[2]
      var task = /^\[([ xX])\]\s+(.*)$/.exec(body)
      if (task) body = (task[1].trim() === "" ? "☐ " : "☑ ") + task[2]
      else body = "• " + body
      html.push('<p>' + pad + inlineMarkdown(escapeHtml(body)) + '</p>')
      i++
      continue
    }

    if (/^---+$/.test(line)) {
      html.push("<hr>")
      i++
      continue
    }

    if (/^>\s?/.test(line)) {
      html.push('<p><i>' + inlineMarkdown(escapeHtml(line.replace(/^>\s?/, ""))) + '</i></p>')
      i++
      continue
    }

    html.push("<p>" + inlineMarkdown(escapeHtml(line)) + "</p>")
    i++
  }
  return '<html><body style="line-height:125%">' + html.join("") + "</body></html>"
}
