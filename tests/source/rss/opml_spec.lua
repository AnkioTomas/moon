local Assert = require("support.assert")
local OPML = require("source.rss.opml")

local path = os.tmpname() .. ".opml"
local f = assert(io.open(path, "wb"))
f:write([[
<opml version="2.0"><body>
  <outline text="Example &amp; News" type="rss"
           xmlUrl="https://example.com/feed.xml"/>
  <outline title="Atom" xmlUrl='https://example.org/atom.xml'/>
  <outline text="Folder"><outline text="Nested"
           xmlUrl="https://nested.example/feed"/></outline>
</body></opml>
]])
f:close()

local feeds, err = OPML.read(path)
os.remove(path)
Assert.eq(err, nil)
Assert.eq(#feeds, 3)
Assert.eq(feeds[1].title, "Example & News")
Assert.eq(feeds[1].url, "https://example.com/feed.xml")
Assert.eq(feeds[2].title, "Atom")
Assert.eq(feeds[3].title, "Nested")
