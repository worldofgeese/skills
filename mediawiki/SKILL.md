---
name: mediawiki
description: Read, create, edit, search, and upload to the White Cat Adventures MediaWiki. Use when interacting with the campaign wiki at whitecatadventures.miraheze.org — reading pages, writing session summaries, editing house rules, uploading images, or listing content.
---

# MediaWiki Skill — White Cat Adventures

## Wiki

- **URL:** https://whitecatadventures.miraheze.org
- **API:** https://whitecatadventures.miraheze.org/w/api.php
- **MediaWiki version:** 1.45.1
- **Content format:** wikitext

## Credentials

- **Bot username:** `Mother@Mother@Spöke`
- **Bot password:** Stored as environment variable, `WHITE_CAT_ADVENTURES_BOT_TOKEN`
 
## Authentication Flow

Authentication uses cookies. All three steps are required before any write operation.

```bash
# 1. Get login token
LOGIN_TOKEN=$(curl -s -c /tmp/wiki-cookies.txt \
  'https://whitecatadventures.miraheze.org/w/api.php?action=query&meta=tokens&type=login&format=json' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['query']['tokens']['logintoken'])")

# 2. Login
curl -s -b /tmp/wiki-cookies.txt -c /tmp/wiki-cookies.txt \
  -X POST 'https://whitecatadventures.miraheze.org/w/api.php' \
  --data-urlencode "action=login" \
  --data-urlencode "lgname=Mother@Loving_Kypris" \
  --data-urlencode "lgpassword=$(ssh -i ~/.ssh/id_ed25519_paphos -o IdentitiesOnly=yes kypris@192.168.99.104 'echo Caress-Playgroup-Legibly4-Removed | sudo -S cat /run/agenix/mediawiki-bot-password 2>/dev/null')" \
  --data-urlencode "lgtoken=${LOGIN_TOKEN}" \
  --data-urlencode "format=json"

# 3. Get CSRF token (needed for edits, uploads, deletes, moves)
CSRF_TOKEN=$(curl -s -b /tmp/wiki-cookies.txt \
  'https://whitecatadventures.miraheze.org/w/api.php?action=query&meta=tokens&type=csrf&format=json' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['query']['tokens']['csrftoken'])")
```

After this, pass `-b /tmp/wiki-cookies.txt` to all subsequent requests.

## Helper Script

For convenience, source the login helper before operations:

```bash
source /home/node/.openclaw/workspace/skills/mediawiki/wiki-login.sh
# Sets: WIKI_API, CSRF_TOKEN, cookie jar at /tmp/wiki-cookies.txt
```

## Operations

### Read a page (raw wikitext)

```bash
curl -s -b /tmp/wiki-cookies.txt \
  "${WIKI_API}?action=query&titles=PAGE_TITLE&prop=revisions&rvprop=content&rvslots=main&format=json" \
  | python3 -c "import sys,json; pages=json.load(sys.stdin)['query']['pages']; print(list(pages.values())[0]['revisions'][0]['slots']['main']['*'])"
```

### Read a page (rendered HTML → markdown)

Use `web_fetch` for convenience:
```
web_fetch url:"https://whitecatadventures.miraheze.org/wiki/PAGE_TITLE"
```

### Create or edit a page

Write content to a file first (never inline wikitext in shell commands):

```bash
cat > /tmp/wiki-content.txt << 'WIKIEOF'
== Section ==
Your wikitext here.
WIKIEOF

curl -s -b /tmp/wiki-cookies.txt -X POST "${WIKI_API}" \
  --data-urlencode "action=edit" \
  --data-urlencode "title=Page Title" \
  --data-urlencode "text@/tmp/wiki-content.txt" \
  --data-urlencode "summary=Edit summary" \
  --data-urlencode "token=${CSRF_TOKEN}" \
  --data-urlencode "format=json"
```

To edit a specific section only:
```bash
# Add &section=N to the edit request (0 = lead, 1+ = sections in order)
--data-urlencode "section=2"
```

To append to a page instead of replacing:
```bash
--data-urlencode "appendtext@/tmp/wiki-append.txt"
# (use appendtext instead of text)
```

### Search

```bash
curl -s -b /tmp/wiki-cookies.txt \
  "${WIKI_API}?action=query&list=search&srsearch=QUERY&format=json"
```

### List all pages

```bash
curl -s -b /tmp/wiki-cookies.txt \
  "${WIKI_API}?action=query&list=allpages&aplimit=500&format=json"
```

### Recent changes

```bash
curl -s -b /tmp/wiki-cookies.txt \
  "${WIKI_API}?action=query&list=recentchanges&rclimit=20&rcprop=title|timestamp|user|comment&format=json"
```

### Upload a file

```bash
curl -s -b /tmp/wiki-cookies.txt -X POST "${WIKI_API}" \
  -F "action=upload" \
  -F "filename=My_Image.png" \
  -F "file=@/path/to/image.png" \
  -F "comment=Upload description" \
  -F "token=${CSRF_TOKEN}" \
  -F "format=json"
```

### Move (rename) a page

```bash
curl -s -b /tmp/wiki-cookies.txt -X POST "${WIKI_API}" \
  --data-urlencode "action=move" \
  --data-urlencode "from=Old Title" \
  --data-urlencode "to=New Title" \
  --data-urlencode "reason=Rename reason" \
  --data-urlencode "token=${CSRF_TOKEN}" \
  --data-urlencode "format=json"
```

### Delete a page

```bash
curl -s -b /tmp/wiki-cookies.txt -X POST "${WIKI_API}" \
  --data-urlencode "action=delete" \
  --data-urlencode "title=Page Title" \
  --data-urlencode "reason=Deletion reason" \
  --data-urlencode "token=${CSRF_TOKEN}" \
  --data-urlencode "format=json"
```

## Available Rights

Create, move, or edit pages.

## Wiki Structure

The wiki covers three game systems:

| Game | Naming Convention | Examples |
|------|-------------------|----------|
| Savage Kingdoms (IKRPG) | `C{season}E{episode}: Title` | C1E1: The raided village |
| EverQuest RPG | `C{season}E{episode}: Title` | C3E9: The Ignominious Death of the Pumpkin Man |
| Necromunda | Campaign-grouped | The Expendables, Deep-Dive Demons, Fall of Hive Arcos |

Other pages: character sheets, house rules, learner's guides, mechanics references, memorials.

Total pages: ~100. Images hosted on static.wikitide.net.

## Wikitext Formatting Reference

> Source: [MediaWiki Help:Formatting](https://www.mediawiki.org/wiki/Help:Formatting)

### Critical: Paragraphs & Line Breaks

**Single newlines are IGNORED in wikitext.** Two consecutive lines render as one paragraph.

```wikitext
This line
and this line
become one paragraph.

A blank line starts a new paragraph.

Use <br/> for a line break within a paragraph.
```

**This is the #1 formatting mistake.** If you want fields on separate lines (like Goal/Belief/Moment in character reviews), put a **blank line** between them or use `<br/>`.

### Inline Formatting

```wikitext
''italic''           → two apostrophes each side
'''bold'''           → three apostrophes each side
'''''bold italic'''' → five apostrophes each side
```

**Use STRAIGHT apostrophes only** (`'` U+0027) for wiki markup. Curly/smart quotes (`'` U+2019) break most markup.

**Exception:** Some canonical page titles use curly apostrophes (e.g., `Os'Bulzog`). Match the page title exactly for links: `[[Os'Bulzog]]`.

### Headings

```wikitext
== Level 2 ==       (page sections)
=== Level 3 ===     (subsections)
==== Level 4 ====   (sub-subsections)
```

Skip level 1 — it's the page title. 4+ headings auto-generate a table of contents (suppress with `__NOTOC__`).

### Lists

```wikitext
* Bullet item             (asterisk)
** Nested bullet          (more asterisks)
# Numbered item           (hash)
## Nested numbered
; Term                    (definition list)
: Definition
```

### Links

```wikitext
[[Page Title]]                    → internal link
[[Page Title|display text]]       → piped internal link
[https://example.com text]        → external link
[[File:Image.jpg|thumb|Caption]]  → image embed
[[Category:Name]]                 → categorize page
```

### Tables

```wikitext
{| class="wikitable"
|-
! Header 1 !! Header 2
|-
| Cell 1 || Cell 2
|-
| Cell 3 || Cell 4
|}
```

### HTML Subset

These HTML tags work in wikitext:
- `<br/>` — line break (critical for formatting)
- `<blockquote>` — block quote
- `<nowiki>` — escape wiki markup
- `<noinclude>` — content hidden from transclusion (we use for agent context blocks)
- `<ref>` / `<references/>` — footnotes
- `<code>`, `<pre>` — code formatting
- `<div>`, `<span>` — with `class` or `style` attributes

### Preformatted Text

```wikitext
 Start line with a space → preformatted (monospace, no wrapping)
<pre>Block of preformatted text</pre>
<code>Inline code</code>
```

## Rules

1. **Always write wikitext to a file first.** Never inline it in curl commands — shell quoting will break on wikitext special characters.
2. **Ask before deleting.** The delete right is available but destructive. Confirm with Tao first.
3. **Use meaningful edit summaries.** The wiki has other users (players edit anonymously).
4. **Respect existing page structure.** Read the current wikitext before editing to match the established style.
5. **Session summaries follow the existing pattern.** Check a recent session page for the wiki's narrative style before writing new ones.
