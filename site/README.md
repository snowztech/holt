# Holt website

The landing page for [Holt](https://github.com/snowztech/holt). Plain HTML, CSS and a little JS, no build step. Components and tokens come from [`@snowztech/ui-css`](https://github.com/snowztech/ui) over the CDN, with Holt's colors on top in `style.css`.

## Preview

```sh
cd site
python3 -m http.server 8000
# open http://localhost:8000
```

## Deploy

Any static host works. Upload this folder as is.

For GitHub Pages from this repo: Settings → Pages → Source: GitHub Actions, then add a workflow that uploads `site/` with `actions/upload-pages-artifact`. Add a `CNAME` file here once there's a domain.

## Notes

- The hero popup is HTML, not a screenshot, so it stays sharp and follows the light and dark theme. It mirrors `apple/Sources/Holt/Popup.swift`; update it when the app's look changes.
- Skip (`#skip`), Skip's face for the logo (`#skip-face`) and the one-color mark (`#mark`) are inline SVG, the same shapes the app draws in `Brand.swift`.
- `assets/popup-dark.png` and `popup-light.png` are the README picture: the hero popup rendered at 2x in headless Chrome.
- `assets/icon-512.png` comes from `make icon` in the repo root (`build/icon-1024.png`, resized).
