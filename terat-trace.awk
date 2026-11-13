# terat-trace.awk - turn pi's --mode json event stream into one OTLP trace.
#
# Reads the events on stdin, writes an OTLP/HTTP JSON request body on stdout.
# Nothing else in terat knows what a span is: tert posts this body with curl, so
# tracing needs no SDK, no collector and no background process when it is off.
#
# The shape: one root span for the question, a child span per model turn and a
# child span per tool call. Token counts and the model name come from the events
# pi already emits, so the trace costs nothing extra and cannot disagree with
# what was actually run.

function esc(s,   out, i, c, n) {
	out = ""
	n = length(s)
	for (i = 1; i <= n; i++) {
		c = substr(s, i, 1)
		if (c == "\\") out = out "\\\\"
		else if (c == "\"") out = out "\\\""
		else if (c == "\n") out = out "\\n"
		else if (c == "\r") out = out "\\r"
		else if (c == "\t") out = out "\\t"
		else if (c < " ") out = out " "
		else out = out c
	}
	return out
}

# Where the LAST "key": starts, or 0. The events put content before metadata and
# content is arbitrary prose, so a field is the last match, not the first.
function at(line, key,   pat, from, pos, found) {
	pat = "\"" key "\":"
	from = 1
	found = 0
	while ((pos = index(substr(line, from), pat)) > 0) {
		found = from + pos - 1
		from = found + length(pat)
	}
	return found
}

function num(line, key,   p, s) {
	p = at(line, key)
	if (!p) return ""
	s = substr(line, p + length(key) + 3)
	if (!match(s, /^-?[0-9]+/)) return ""
	return substr(s, RSTART, RLENGTH) + 0
}

# First "field": at or after the "object": that owns it, as a number. Usage is
# an object that itself contains a cost object with the same field names, so
# searching the whole line — or taking the last match — reads the zeroed cost
# figures instead of the real token counts.
#
# Decimals matter: costs arrive as 0.000475 and a digits-only match reads that
# as 0, which is indistinguishable from a model with no price at all. The
# fraction is matched too, and a leading-dot form is not valid JSON so it is
# left to the integer case.
function field(obj, line, f,   p, s) {
	p = index(line, "\"" obj "\":")
	if (!p) return ""
	s = substr(line, p)
	p = index(s, "\"" f "\":")
	if (!p) return ""
	s = substr(s, p + length(f) + 3)
	if (!match(s, /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?/)) return ""
	return substr(s, RSTART, RLENGTH) + 0
}

function str(line, key,   p, s, i, c, out) {
	p = at(line, key)
	if (!p) return ""
	s = substr(line, p + length(key) + 3)
	if (substr(s, 1, 1) != "\"") return ""
	out = ""
	for (i = 2; i <= length(s); i++) {
		c = substr(s, i, 1)
		if (c == "\\") { i++; out = out substr(s, i, 1) }
		else if (c == "\"") break
		else out = out c
	}
	return out
}

function ns(ms) {
	if (ms == "") return ""
	return sprintf("%.0f", ms) "000000"
}

function A(k, v) {
	return "{\"key\":\"" esc(k) "\",\"value\":{\"stringValue\":\"" esc(v) "\"}}"
}

function I(k, v) {
	return "{\"key\":\"" esc(k) "\",\"value\":{\"intValue\":\"" v "\"}}"
}

# Laminar reads cost as a JSON number and ignores a string or an int, so cost
# attributes cannot go through A() or I(). printf with no exponent, because awk
# would otherwise render small amounts as 1e-05 and some JSON readers disagree
# about that being a number.
function D(k, v) {
	if (v == "") v = 0
	return "{\"key\":\"" esc(k) "\",\"value\":{\"doubleValue\":" sprintf("%.10f", v + 0) "}}"
}

# One chat message, as JSON, for the input/output attributes. Laminar parses
# these into conversation turns: `role` plus `content` is the whole contract, and
# `content` as a plain string is accepted for both.
function msg(role, text) {
	return "{\"role\":\"" role "\",\"content\":\"" esc(text) "\"}"
}

function msgs(role, text) {
	return "[" msg(role, text) "]"
}

# The text of a `content` array, joined. pi emits content as parts —
# `[{"type":"text","text":"..."}]` — so the raw text of the turn is the
# concatenation of its text parts, not the first "text": that appears.
function parts(line, key,   p, s, i, out, t) {
	p = index(line, "\"" key "\":[")
	if (!p) return ""
	s = substr(line, p)
	out = ""
	# Walk every text part; a tool-call part carries no prose and is skipped.
	while (match(s, /\{"type":"text","text":"/)) {
		s = substr(s, RSTART + RLENGTH)
		t = ""
		for (i = 1; i <= length(s); i++) {
			c = substr(s, i, 1)
			if (c == "\\") { i++; t = t substr(s, i, 1) }
			else if (c == "\"") break
			else t = t c
		}
		if (t != "") out = (out == "") ? t : out "\n" t
		s = substr(s, i)
	}
	return out
}

# A nested object, as JSON text, for attributes that carry structure. Braces are
# counted rather than pattern-matched because tool arguments are themselves JSON
# and contain braces; strings are skipped so a brace in prose cannot end it early.
function obj(line, key,   p, s, i, c, d, out, instr) {
	p = index(line, "\"" key "\":{")
	if (!p) return ""
	s = substr(line, p + length(key) + 3)
	d = 0; instr = 0; out = ""
	for (i = 1; i <= length(s); i++) {
		c = substr(s, i, 1)
		if (instr) {
			if (c == "\\") { out = out c substr(s, i + 1, 1); i++; continue }
			if (c == "\"") instr = 0
			out = out c
			continue
		}
		if (c == "\"") { instr = 1; out = out c; continue }
		if (c == "{") d++
		else if (c == "}") { d--; out = out c; if (d == 0) return out; continue }
		out = out c
	}
	return ""
}

function span(id, parent, name, from, to, attrs, code,   s) {
	s = "{\"traceId\":\"" trace "\",\"spanId\":\"" id "\","
	if (parent != "") s = s "\"parentSpanId\":\"" parent "\","
	s = s "\"name\":\"" esc(name) "\",\"kind\":1,"
	s = s "\"startTimeUnixNano\":\"" ns(from) "\","
	s = s "\"endTimeUnixNano\":\"" ns(to) "\","
	s = s "\"attributes\":[" attrs "],"
	s = s "\"status\":{\"code\":" code "}}"
	return s
}

{
	if ($0 ~ /"type":[ ]*"session"/) {
		cwd = str($0, "cwd")
		next
	}
	if ($0 ~ /"type":[ ]*"message_end"/) {
		# The user turn is the question as the harness actually sent it, which
		# is not always the string tert was given: a harness may prepend
		# context. Prefer it over the command line, and keep the last one
		# because that is the turn this trace is about.
		if (str($0, "role") == "user") {
			q = parts($0, "content")
			if (q != "") qtxt = q
			next
		}
		if (str($0, "role") != "assistant") next
		nm++
		m_model[nm] = str($0, "model")
		m_prov[nm] = str($0, "provider")
		m_in[nm] = field("usage", $0, "input")
		m_out[nm] = field("usage", $0, "output")
		m_tot[nm] = field("usage", $0, "totalTokens")
		# Cache reads are billed differently from fresh input tokens and are
		# usually the bulk of a long conversation, so a trace that drops them
		# understates both the token count and the cost.
		m_cr[nm] = field("usage", $0, "cacheRead")
		m_cw[nm] = field("usage", $0, "cacheWrite")
		# pi computes cost per turn from its own price table. It is zero when
		# that table has no price for the model — a subscription or a custom
		# provider — which is not the same as free, and the trace records the
		# zero it was given rather than inventing a number.
		m_cin[nm] = field("cost", $0, "input")
		m_cout[nm] = field("cost", $0, "output")
		m_ctot[nm] = field("cost", $0, "total")
		m_dur[nm] = num($0, "durationMs")
		m_ts[nm] = num($0, "timestamp")
		# The model's prose for this turn. A turn that only calls a tool has
		# none, which is why this is allowed to stay empty.
		m_text[nm] = parts($0, "content")
		ne++; kind[ne] = "m"; ref[ne] = nm
		next
	}
	if ($0 ~ /"type":[ ]*"tool_execution_start"/) {
		# The arguments are the only record of what the tool was asked to do,
		# and they arrive before the call finishes, so hold them by id and
		# pick them up when the matching end event lands.
		t_args[str($0, "toolCallId")] = obj($0, "args")
		next
	}
	if ($0 ~ /"type":[ ]*"tool_execution_end"/) {
		nt++
		t_name[nt] = str($0, "toolName")
		t_dur[nt] = num($0, "durationMs")
		t_err[nt] = ($0 ~ /"isError":[ ]*true/) ? 1 : 0
		t_arg[nt] = t_args[str($0, "toolCallId")]
		t_res[nt] = obj($0, "result")
		ne++; kind[ne] = "t"; ref[ne] = nt
		next
	}
}

END {
	# A harness other than pi answers in plain text, so there are no events to
	# read. The question still happened and still took time, so send the root
	# span alone rather than nothing: one span that says which question was
	# asked, in which directory, and how long it took. Silence would make it
	# look as though tracing were broken.
	# A trace needs an id: an empty traceId is invalid OTLP and a collector will
	# reject the whole batch. tert always supplies one, so reaching here without
	# it means the caller is doing something else, and silence is the honest
	# answer rather than a request that cannot be accepted.
	if (trace == "") exit 0

	svc = ENVIRON["TERAT_TRACE_SERVICE"]
	if (svc == "") svc = "terat"
	# pi names the directory in its session event; anything else leaves it
	# blank, so start from where tert ran and let the session event override.
	if (cwd == "") cwd = ENVIRON["TERAT_TRACE_CWD"]

	# Anchor the timeline. Model turns carry absolute times; a tool call only
	# reports how long it took, so it is laid down after whatever came before
	# it. That keeps the spans in the order they happened without inventing
	# clock readings the stream does not contain.
	cursor = 0
	for (i = 1; i <= ne; i++) {
		if (kind[i] == "m" && m_ts[ref[i]] != "" && m_dur[ref[i]] != "") {
			cursor = m_ts[ref[i]] - m_dur[ref[i]]
			break
		}
	}
	# Without events there is no clock in the stream, so fall back to when tert
	# started, and let the root span run to now. That is the whole answer for a
	# plain-text harness: one span, honest duration, nothing invented.
	if (cursor == 0) cursor = (began != "" && began + 0 > 0) ? began + 0 : nowms
	start = cursor
	if (ne == 0) cursor = nowms

	root = substr(seed, 1, 9) sprintf("%07x", 0)
	nchild = 0
	for (i = 1; i <= ne; i++) {
		if (kind[i] == "m") {
			j = ref[i]
			to = m_ts[j]
			from = (to == "" || m_dur[j] == "") ? cursor : to - m_dur[j]
			if (from < cursor) from = cursor
			if (to == "" || to < from) to = from + (m_dur[j] == "" ? 0 : m_dur[j])
			a = A("lmnr.span.type", "LLM")
			a = a "," A("terat.kind", "model")
			if (m_prov[j] != "") a = a "," A("gen_ai.system", m_prov[j])
			if (m_model[j] != "") a = a "," A("gen_ai.usage.request_model", m_model[j])
			if (m_model[j] != "") a = a "," A("gen_ai.response.model", m_model[j])
			if (m_in[j] != "") a = a "," I("gen_ai.usage.input_tokens", m_in[j])
			if (m_out[j] != "") a = a "," I("gen_ai.usage.output_tokens", m_out[j])
			if (m_tot[j] != "") a = a "," I("llm.usage.total_tokens", m_tot[j])
			if (m_cr[j] != "" && m_cr[j] > 0) a = a "," I("gen_ai.usage.cache_read_input_tokens", m_cr[j])
			if (m_cw[j] != "" && m_cw[j] > 0) a = a "," I("gen_ai.usage.cache_creation_input_tokens", m_cw[j])
			# Emitted even when zero: a span with no cost attributes is left
			# blank, while an explicit 0 says "this model reported no price",
			# which is the honest reading of a subscription plan.
			a = a "," D("gen_ai.usage.input_cost", m_cin[j])
			a = a "," D("gen_ai.usage.output_cost", m_cout[j])
			a = a "," D("gen_ai.usage.cost", m_ctot[j])
			# An LLM span with no messages shows an empty panel. The turn's own
			# prompt is the question, and its completion is the prose the model
			# returned; tool-call turns have no prose and get no output.
			a = a "," A("gen_ai.input.messages", msgs("user", (qtxt != "" ? qtxt : ENVIRON["TERAT_TRACE_Q"])))
			if (m_text[j] != "") a = a "," A("gen_ai.output.messages", msgs("assistant", m_text[j]))
			nchild++
			cid = substr(seed, 1, 9) sprintf("%07x", nchild)
			name = (m_model[j] != "") ? "chat " m_model[j] : "chat"
			spans = spans (nchild > 1 ? "," : "") span(cid, root, name, from, to, a, 1)
			cursor = (to > cursor) ? to : cursor
		} else {
			j = ref[i]
			from = cursor
			to = from + (t_dur[j] == "" ? 0 : t_dur[j])
			# TOOL, not DEFAULT: Laminar only reads the call arguments and
			# result on spans it knows are tools, so a tool span typed DEFAULT
			# renders those two attributes as no input and no output.
			a = A("lmnr.span.type", "TOOL")
			a = a "," A("terat.kind", "tool")
			if (t_name[j] != "") a = a "," A("gen_ai.tool.name", t_name[j])
			if (t_err[j]) a = a "," A("terat.tool.error", "true")
			nchild++
			cid = substr(seed, 1, 9) sprintf("%07x", nchild)
			name = (t_name[j] != "") ? "tool " t_name[j] : "tool"
			# Without these a tool span shows which tool ran but not what it
			# was given or what it returned, which is most of its value.
			if (t_arg[j] != "") a = a "," A("gen_ai.tool.call.arguments", t_arg[j])
			if (t_res[j] != "") a = a "," A("gen_ai.tool.call.result", t_res[j])
			spans = spans (nchild > 1 ? "," : "") span(cid, root, name, from, to, a, t_err[j] ? 2 : 1)
			cursor = to
		}
	}

	# What Laminar actually renders. `gen_ai.prompt.*` is a legacy path; the
	# panels read `lmnr.span.input` and `lmnr.span.output`, and parse them as
	# JSON — a bare string arrives as the string it is, so the shape has to be
	# an array of chat messages. Without these the span shows `null` for input
	# and output however many gen_ai attributes ride beside it.
	ra = A("lmnr.span.type", "DEFAULT")
	ra = ra "," A("terat.cwd", cwd)
	qs = (qtxt != "") ? qtxt : ENVIRON["TERAT_TRACE_Q"]
	ra = ra "," A("lmnr.span.input", msgs("user", qs))
	if (ENVIRON["TERAT_TRACE_A"] != "") ra = ra "," A("lmnr.span.output", msgs("assistant", ENVIRON["TERAT_TRACE_A"]))

	rootspan = span(root, "", "terat.ask", start, cursor, ra, 1)

	printf "{\"resourceSpans\":[{\"resource\":{\"attributes\":["
	printf "%s", A("service.name", svc)
	printf "]},\"scopeSpans\":[{\"scope\":{\"name\":\"terat\"},\"spans\":["
	printf "%s", rootspan
	if (spans != "") printf ",%s", spans
	printf "]}]}]}\n"
}
