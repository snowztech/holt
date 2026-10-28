# Holt website

The landing page for [Holt](https://github.com/snowztech/holt). Plain HTML, CSS and a little JS, no build step. Components and tokens come from [`@snowztech/ui-css`](https://github.com/snowztech/ui) over the CDN, with Holt's colors on top in `style.css`.

## Preview

```sh
cd site
python3 -m http.server 8000
# open http://localhost:8000
```

## Deploy

`.github/workflows/site.yml` publishes this folder to GitHub Pages on every push to main that touches `site/`. Run it by hand from the Actions tab too.

It's served at https://holt.snowztech.com: a CNAME record `holt` → `snowztech.github.io` at Hostinger, and the custom domain set in the repo's Settings → Pages. With a workflow deploy, GitHub uses that setting, not a `CNAME` file.

## Notes

- `docs.html` is the user guide at `/docs`. It's the one place that explains every feature, and the repo README links to it, so update it when a feature or a setting changes.
- The hero popup is HTML, not a screenshot, so it stays sharp and follows the light and dark theme. It mirrors `apple/Sources/Holt/Popup.swift`; update it when the app's look changes.
- Skip (`#skip`) and Skip's face, the logo (`#skip-face`), are inline SVG, the same shapes the app draws from `SkipFace` in `Brand.swift`.
- `assets/readme-hero-dark.png` and `readme-hero-light.png` are the README picture: the hero popup rendered 720 CSS pixels wide at 2x in headless Chrome, with a transparent background. The README shows it at `width="720"`, so it's never scaled.
- `assets/icon-512.png` comes from `make icon` in the repo root (`build/icon-1024.png`, resized).
- `assets/og.png` is the 1280×640 share image, for link previews and the GitHub social preview. It's the logo, the headline and the hero popup, rendered in headless Chrome.
