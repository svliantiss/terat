# terat-acp.awk - the three JSON jobs the ACP bridge cannot do in sh.
#
# ACP is JSON-RPC; terat is sed and case statements. Between them the only hard
# parts are reading a field out of a request and writing a string back out safely.
# That is all this file is. The protocol lives in terat's `acp)` branch, where it
# can be read top to bottom: one case per method, one line per field.
#
# Modes, chosen with -v mode=:
#   get   print one field of the request on stdin, named by -v k=
#   text  print the text of every content block in a session/prompt
#   esc   escape stdin so it can sit inside a JSON string
#
# Deliberately not a parser. A real one is the interpreter dependency terat's
# install story exists to avoid, and every field read here is a top-level scalar.

# A top-level scalar, printed with its JSON type intact: a client that sends a
# numeric id must not get a quoted one back. An absent field prints nothing, which
# every caller reads as "not given".
function scalar(txt, k,   pat, raw) {
	pat = "\"" k "\"[ \t]*:[ \t]*\"([^\"\\\\]|\\\\.)*\""
	if (match(txt, pat)) {
		raw = substr(txt, RSTART, RLENGTH)
		sub("^\"" k "\"[ \t]*:[ \t]*", "", raw)
		return raw
	}
	pat = "\"" k "\"[ \t]*:[ \t]*[-0-9]+"
	if (match(txt, pat)) {
		raw = substr(txt, RSTART, RLENGTH)
		sub("^\"" k "\"[ \t]*:[ \t]*", "", raw)
		return raw
	}
	return ""
}

# A field as bare text: quotes stripped, escapes resolved. For a path or a value,
# where the JSON wrapper is noise.
function bare(txt, k,   v) {
	v = scalar(txt, k)
	if (substr(v, 1, 1) == "\"") v = substr(v, 2, length(v) - 2)
	gsub(/\\"/, "\"", v)
	gsub(/\\n/, "\n", v)
	gsub(/\\t/, "\t", v)
	gsub(/\\\\/, "\\", v)
	return v
}

BEGIN {
	if (mode == "esc") {
		# stdin is the whole question, and a question may hold a newline while a
		# JSON string may not, so it is read as one string and escaped.
		out = ""
		while ((getline line) > 0) out = out (out == "" ? "" : "\n") line
		if (out ~ /["\\\t\r\n]/) {
			res = ""
			n = length(out)
			for (i = 1; i <= n; i++) {
				c = substr(out, i, 1)
				if (c == "\\") res = res "\\\\"
				else if (c == "\"") res = res "\\\""
				else if (c == "\t") res = res "\\t"
				else if (c == "\r") res = res "\\r"
				else if (c == "\n") res = res "\\n"
				else res = res c
			}
			out = res
		}
		printf "%s", out
		exit 0
	}
}

mode == "get" {
	printf "%s", bare($0, k)
	next
}

# The JSON-RPC id, kept exactly as it arrived. Ids are the one field whose type
# matters: a client that sent the string "abc" must get "abc" back, quoted, or
# the reply is not JSON at all - and a numeric id must not gain quotes either.
mode == "id" {
	printf "%s", scalar($0, "id")
	next
}

mode == "text" {
	# The prompt is an array of content blocks; joining the text ones is the whole
	# of what this bridge accepts. A question split across blocks is one question.
	rest = $0
	while (match(rest, "\"text\"[ \t]*:[ \t]*\"")) {
		rest = substr(rest, RSTART + RLENGTH)
		v = ""
		open = 1
		while (open && rest != "") {
			c = substr(rest, 1, 1)
			rest = substr(rest, 2)
			if (c == "\\") { v = v c substr(rest, 1, 1); rest = substr(rest, 2) }
			else if (c == "\"") open = 0
			else v = v c
		}
		gsub(/\\"/, "\"", v)
		gsub(/\\n/, "\n", v)
		gsub(/\\t/, "\t", v)
		gsub(/\\\\/, "\\", v)
		printf "%s\n", v
	}
}
