# Website SEO audit

HOL-3 · 11 November 2026 · source revision `fd247e8`

The best first change is to say what Holt does in page titles. Next, verify the live URLs and declare a preferred URL for each page. The site already has useful content. It does not need a stack of near-identical keyword pages.

## Scope and limits

Reviewed `site/index.html`, `site/docs.html`, `site/privacy.html`, shared CSS and JavaScript, `site/README.md` and `.github/workflows/site.yml`. The workflow publishes `site/` directly to GitHub Pages. Repository files under `docs/` are not part of that website; the public user guide is `site/docs.html`.

This is a source audit. Browser-tool requests to the live homepage and `/docs` failed. That does not establish an outage. Live response codes, redirects, headers, indexing, search traffic and Core Web Vitals remain unverified. No Search Console data was available. Proposed search terms below are content hypotheses, not measured demand. No website changes were made.

## What already works

- Each public page has a title, a distinct meta description, one H1, an English language declaration and a viewport tag.
- Main content and navigation are in HTML. The local script animates the hero demo; it does not supply the article text.
- The guide covers installation, search, pins, pairing, iPhone limits and troubleshooting. Its contents list links to section IDs.
- Navigation links the homepage, guide and privacy page. Open Graph and large-image card metadata already exist.
- CSS includes mobile layouts and reduced-motion rules. These are source findings, not a mobile usability pass.

## Priorities

Priority reflects likely usefulness and effort, not a promised ranking gain.

| Priority | Evidence | Recommended work | Owner / effort | Acceptance check |
| --- | --- | --- | --- | --- |
| 1 | Homepage title is “Holt, your clipboard, kept”; guide title is “Docs, Holt”. Neither names the product category. | Use descriptive titles and make the opening copy explicit. Drafts below. | Marketing / small | Each title describes its page. Copy still matches the app and platform limits. |
| 1 | No `rel="canonical"` in any of the three HTML pages. Links use `/docs` and `/privacy`, while deployed files have `.html` names. | Check live URL variants, then add absolute self-canonicals to the preferred URLs. Keep internal links and `og:url` consistent. | Engineering / small, after live checks | Preferred URLs return 200; variants redirect or declare the same canonical. No canonical points to a 404. |
| 2 | Feature sections mostly leave readers with general navigation links. | Add contextual links from homepage search, sync and privacy sections to the relevant guide sections. | Marketing / small | Links such as “Search your clipboard history” and “Pair two Macs” reach `docs#popup` and `docs#sync`. Check `docs#privacy` too. |
| 2 | Guide headings include “Find and paste”, “Pins” and “iPhone”. | Make selected headings more descriptive without changing their IDs. Keep the contents list aligned. | Marketing / small | Existing deep links still work. Headings clearly describe the task. |
| 2 | Pages request Google Fonts and CDN CSS/JS. The hero runs an ongoing animation. | Measure mobile loading and interaction before changing assets. Check font shifts, CSS delivery and animation cost. | Engineering / medium | Record Lighthouse diagnostics and available field data for homepage and guide. Fix measured bottlenecks. |
| 3 | No sitemap or robots file in the deployed source folder. | Add a small sitemap after URL verification. Optionally add a robots file that points to it and permits public pages. | Engineering / small | Sitemap contains only preferred, live URLs; no section fragments. Submit in Search Console if access exists. |
| 3 | Privacy page uses the homepage Open Graph title and description. | Give privacy its own social title and summary; align other social copy with revised page titles. | Marketing / small | A privacy link preview describes privacy. Treat this as sharing polish, not a ranking fix. |

Google recommends concise, descriptive [page titles](https://developers.google.com/search/docs/appearance/title-link). Canonicals help consolidate URL variants, but their absence alone does not prove an indexing problem. See Google's [canonical guidance](https://developers.google.com/search/docs/crawling-indexing/consolidate-duplicate-urls).

A sitemap is optional for a small, well-linked site. Missing `robots.txt` is not evidence that crawling is blocked. Do not use robots rules to hide duplicate URL variants. See Google's [sitemap guidance](https://developers.google.com/search/docs/crawling-indexing/sitemaps/overview). Performance work should follow measurement; a perfect score is not a ranking guarantee. See [page experience guidance](https://developers.google.com/search/docs/appearance/page-experience).

## Proposed copy and search intent

| Page | Proposed title | Reader intent |
| --- | --- | --- |
| `/` | Holt: Free, open source clipboard manager for Mac | Find a Mac clipboard manager or searchable clipboard history. |
| `/docs` | Holt guide: Clipboard history and sync on Mac | Install Holt, find copied text or pair Macs. |
| `/privacy` | Holt privacy: How your clipboard data is handled | Understand storage, sync and data handling. |

Homepage description: “Search copied text and images, pin clips, and sync clipboard history between paired Macs. Holt is free and open source. No account or Holt server.”

Guide description: “Install Holt on Mac. Search and paste clipboard history, pin clips, pair Macs, and send text from the iPhone beta. Includes shortcuts and troubleshooting.”

Keep the homepage slogan if desired. Start the paragraph beneath it with “Holt is a free, open source clipboard manager for Mac.” Follow with the shortcut and pairing explanation. Replace the broad promise that Holt remembers “everything” with language that allows for private copies and ignored apps.

Suggested guide headings:

- H1: “Holt user guide: Clipboard history on Mac”.
- `#popup`: “Find and paste clipboard history”.
- `#pins`: “Pin clips you reuse”.
- `#iphone`: “Send clips between iPhone and Mac”, keeping the beta badge and limits nearby.

Keep one complete guide for now. Consider separate installation or sync guides only when search queries or support questions justify them. Keep Mac requirements visible: macOS 14 or later, Apple Silicon. Do not target “automatic iPhone clipboard history”: iOS cannot monitor the clipboard in the background. “No Holt server” must not become “no servers”; the privacy page explains third-party discovery and encrypted relays.

## Live checks and measurement handoff

Engineering should check HTTPS responses for `/`, `/index.html`, `/docs`, `/docs.html`, `/privacy` and `/privacy.html`, plus HTTP and the default Pages hostname. Record redirects, final URLs and any `X-Robots-Tag` headers. Check the live robots file and sitemap independently of the source tree. Use the existing clean URLs as the preferred convention only if live checks support them.

The site owner should inspect homepage and guide URLs in Search Console: fetchability, indexing status, Google-selected canonical and rendered content. Record the reason for any exclusion before changing anything. This audit can be used without account access; the indexing baseline cannot.

Before publishing fixes, save the available 28-day baseline for impressions, clicks, click-through rate and average position, split by page and branded versus non-branded queries. Compare the next complete 28-day period after recrawling. Record deployment dates and allow for low traffic. Search Console clicks do not measure app installs.

After changes, check title uniqueness, descriptions, canonical targets, internal links and existing guide fragments. View both pages on a narrow screen with working fonts and styles. Confirm content remains available without JavaScript. Record mobile performance results separately from source checks.

## Audit validation

Cross-checked the findings against the HTML, shared assets and deploy workflow. Reviewed the proposed copy against the company product description and the guide's iPhone and privacy limits. This ticket adds documentation only; no app build or test is needed.
