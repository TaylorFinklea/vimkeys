// VimKeys Bookmark Sync — pushes bookmark snapshots to the native
// SafariWebExtensionHandler via runtime messaging whenever Safari's
// bookmarks tree changes. The native side persists the snapshot in the
// App Group container; VimKeys.app reads from there.
//
// The first arg to sendNativeMessage is the containing app's bundle
// identifier — Safari routes the message to that app's bundled
// extension's principal class.

const NATIVE_APP_ID = "io.taylorfinklea.vimkeys";

async function syncBookmarks() {
  try {
    const tree = await browser.bookmarks.getTree();
    const flat = flattenBookmarks(tree);
    await browser.runtime.sendNativeMessage(NATIVE_APP_ID, {
      action: "syncBookmarks",
      bookmarks: flat,
    });
  } catch (e) {
    console.error("VimKeys: bookmark sync failed", e);
  }
}

// Recursive depth-first flatten. Only emit nodes with a `url` field —
// folder nodes carry no useful info for fuzzy-search and are ignored,
// matching how the HTML-export path treats them.
function flattenBookmarks(nodes) {
  const out = [];
  function walk(node) {
    if (node.url) {
      out.push({ title: node.title || "", url: node.url });
    }
    if (node.children) {
      for (const child of node.children) walk(child);
    }
  }
  for (const n of nodes) walk(n);
  return out;
}

// Sync once at extension startup so the first b/B press after enabling
// the extension has fresh data, then on every change event.
syncBookmarks();
browser.bookmarks.onCreated.addListener(syncBookmarks);
browser.bookmarks.onChanged.addListener(syncBookmarks);
browser.bookmarks.onMoved.addListener(syncBookmarks);
browser.bookmarks.onRemoved.addListener(syncBookmarks);
