def unslack:
  gsub("<@[A-Z0-9]+\\|(?<n>[^>]*)>"; "@\(.n)")
  | gsub("<#[A-Z0-9]+\\|(?<n>[^>]*)>"; "#\(.n)")
  | gsub("<[^|>]+\\|(?<label>[^>]*)>"; "\(.label)")
  | gsub("<(?<url>https?://[^>]+)>"; "\(.url)")
  | gsub("<@[A-Z0-9]+>"; "@user")
  | gsub("<#[A-Z0-9]+>"; "#channel")
  | gsub("&lt;"; "<")
  | gsub("&gt;"; ">")
  | gsub("&amp;"; "&");

# dstask parses +tag, -tag, project:x, P0-P3, "/" (notes) and "--" (ignore context)
# straight out of the summary, so message text must not be able to produce those tokens.
def neutralize:
  gsub("(?<pre>^|\\s)(?<s>[+/-])"; "\(.pre)\(.s)​")
  | gsub("(?<pre>^|\\s)P(?<d>[0-3])(?=\\s|$)"; "\(.pre)P​\(.d)")
  | gsub("(?<pre>^|\\s)(?<k>[-A-Za-z_.]+):(?!//)"; "\(.pre)\(.k)∶");

def first_line:
  split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | (.[0] // "");

def clean_title($max):
  (unslack | first_line | neutralize) as $t
  | if ($t | length) == 0 then "Slack message"
    elif ($t | length) > $max then ($t[0:$max - 1] + "…")
    else $t end;

map(select(
    ((.channel_id // "") | type == "string" and length > 0)
    and ((.message_ts // "") | type == "string" and length > 0)
    and ((.permalink // "") | type == "string" and test("^https://"))
  ))
| unique_by(.channel_id + ":" + .message_ts)
| map({
    key: (.channel_id + ":" + .message_ts),
    title: ((.text // "") | tostring | clean_title($max)),
    permalink: .permalink,
    channel: ((.channel_name // .channel_id) | tostring),
    author: ((.author // "unknown") | tostring)
  })
