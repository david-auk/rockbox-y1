# Y1 version-controlled themes and configuration

The project-owned Rockbox overlay is `custom/y1/.rockbox/`. The existing
`build-install-y1-240p.sh` copies it over the installed `.rockbox` resources
and verifies the result during a normal build/deploy.

Use the importer to capture the **real** theme assets from your Y1 or its
mounted SD card; Repomix omitted binary `.bmp` and `.fnt` files.

```bash
# With a connected Y1 (ADB debugging enabled):
./tools/import-y1-rockbox-customizations.sh --from-adb

# Or with the SD card mounted on your Mac:
./tools/import-y1-rockbox-customizations.sh --from-dir "/Volumes/NO NAME/.rockbox"

git status --short -- custom/y1/.rockbox
# Review any third-party theme/font licenses before publishing a public fork.
git add -A -- custom/y1 tools/import-y1-rockbox-customizations.sh
git commit -m "Track Y1 themes and Rockbox configuration"

# Future builds deploy the tracked configuration and resources:
./build-install-y1-240p.sh --no-clean
```

Only `config.cfg`, `themes/`, `wps/`, `icons/`, `fonts/` and `backdrops/` are
imported. This deliberately excludes `database_*.tcd`, playback/resume files,
bookmarks, temporary updates, generated `*.gc` glyph caches and `._*` AppleDouble
sidecars. **`tagnavi_user.config` is NOT imported**: the version tracked in the
repository remains authoritative. If your device settings change, run the
importer again to sync and stage the latest `config.cfg`/theme changes.

CAUTION: The installer deliberately reapplies tracked `config.cfg`, including
volume and other device preferences, whenever you deploy. Runtime settings may
change again while Rockbox is running; these changes do not automatically sync
back to Git. Import before deploying if you want to preserve them.
