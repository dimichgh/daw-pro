---
name: generate-assets
description: Generate UI art assets (app icon, textures, panel backgrounds, onboarding art) with GPT Image via scripts/gen-art.mjs. Requires OPENAI_API_KEY in .env. Pass a description of the asset(s) needed.
---

# Generate Assets

1. Confirm `OPENAI_API_KEY` is set (`.env` or env). If not, stop and tell the user — never prompt for the key value in chat history.
2. Write the prompt(s): always embed the design language — "dark glass cockpit UI, near-black #0B0D12 surfaces, neon cyan/amber/violet glow accents, studio hardware aesthetic, macOS app, no text". For icons request a transparent background and 1024×1024.
3. Run `node scripts/gen-art.mjs --prompt "<prompt>" --out assets/generated/<name>.png [--size 1024x1024] [--transparent]`. The script uses the model from `OPENAI_IMAGE_MODEL` (default gpt-image-2).
4. Review each result (Read the image). Regenerate with a refined prompt if it violates the design language (wrong palette, skeuomorphic clutter, embedded text).
5. Assets land in `assets/generated/` (gitignored). Promote keepers by copying into `Sources/DAWApp/Resources/` and referencing them from code; report which were promoted.
