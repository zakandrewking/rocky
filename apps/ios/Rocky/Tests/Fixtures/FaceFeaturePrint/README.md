# Synthetic face-feature fixtures

These six crops contain three entirely synthetic adult identities, with two mild pose/lighting
variations per identity. They exist only to regression-test deterministic feature extraction and
basic same-person/different-person separation. They are not representative accuracy evidence and
must never be used to choose Rocky's production threshold.

Generated 2026-11-03 with OpenAI's built-in image-generation tool as one 3×2 contact sheet, then
mechanically cropped into 500×500 PNG files. No real person's image or biometric data is present.

Prompt:

> Create a clean 3-row by 2-column contact sheet containing six separate head-and-shoulders
> portrait photographs. Each row must show the exact same fictional adult person twice, while each
> different row is a clearly different fictional identity. Within each row, vary only pose slightly
> (front-facing versus about 15 degrees) and lighting mildly, while preserving unmistakably
> identical facial structure, hair, age, skin tone, and accessories. Across rows use three diverse
> adult identities. Neutral expressions, plain light-gray studio background, even crop, face
> centered, realistic phone-camera texture. All people must be synthetic and not resemble public
> figures; adults only; no names, labels, text, logos, watermark, glasses, hats, or occlusion.

The original contact sheet is intentionally not retained; only the exact crops consumed by tests
are committed.
