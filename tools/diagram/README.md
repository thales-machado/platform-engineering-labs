# Diagram tools

Shared by every lab. Each lab keeps `diagram.mmd` as the source and `diagram.png` as the rendered image. The README embeds the PNG because GitHub cannot show custom icon packs inside a Mermaid block.

## Render

```bash
npm i -g @mermaid-js/mermaid-cli   # once
tools/diagram/render.sh k8s/local
```

`render.sh` installs the icon packs, builds `lab.json` and passes it to `mmdc` as a data URL. Commit `diagram.mmd` and `diagram.png` together.

## Icons

Use them in a flowchart as `id@{ icon: "lab:<name>", form: "rounded", label: "...", pos: "b", h: 40 }`. To add one, edit `build-pack.js`. Sources: Iconify `logos` (color), `simple-icons` and `mdi` (tinted to the layer color).

| Layer | Fill | Stroke |
|---|---|---|
| Kubernetes | `#172554` | `#3b82f6` |
| Network | `#083344` | `#06b6d4` |
| Workloads | `#1e1b4b` | `#818cf8` |
| Observability | `#431407` | `#f97316` |
| GitOps | `#3b0764` | `#c084fc` |
| Host / external | `#1f2937` | `#6b7280` |
