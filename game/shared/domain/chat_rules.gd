class_name ChatRules
extends RefCounted
## What a chat message may look like. The server cleans every message it receives (the client only trims what it sends),
## so a modified client cannot get anything else through. The limits are in balance.json ("chat", PROVISIONAL).


## One line of plain text: control characters and runs of spaces become a single space, then it is cut to `max_length`.
## Returns "" when nothing is left (the message is dropped).
static func clean(text: String, max_length: int) -> String:
	var out := ""
	var last_space := true # leading spaces are dropped
	for i in text.length():
		var code := text.unicode_at(i)
		var blank := code <= 0x20 or code == 0x7f or (code >= 0x80 and code <= 0x9f)
		if blank:
			if not last_space:
				out += " "
			last_space = true
		else:
			out += text[i]
			last_space = false
	return out.strip_edges().left(max_length).strip_edges()
