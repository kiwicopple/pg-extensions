// Canonical sources, routes and sidebar labels.
export const pages = [
  {
    "src": "docs/overview.md",
    "route": "overview",
    "label": "Overview"
  },
  {
    "src": "docs/install.md",
    "route": "install",
    "label": "Install"
  },
  {
    "src": "docs/get-started/quickstart.md",
    "route": "get-started/quickstart",
    "label": "Quickstart"
  },
  {
    "src": "docs/get-started/choose-an-id.md",
    "route": "get-started/choose-an-id",
    "label": "Choose an ID"
  },
  {
    "src": "docs/guides/primary-keys.md",
    "route": "guides/primary-keys",
    "label": "Use IDs as primary keys"
  },
  {
    "src": "docs/guides/timestamps.md",
    "route": "guides/timestamps",
    "label": "Read timestamps"
  },
  {
    "src": "docs/reference/uuid.md",
    "route": "reference/uuid",
    "label": "UUID generators"
  },
  {
    "src": "docs/reference/ksuid.md",
    "route": "reference/ksuid",
    "label": "KSUID generators"
  },
  {
    "src": "docs/reference/timestamps.md",
    "route": "reference/timestamps",
    "label": "Timestamp extraction"
  },
  {
    "src": "docs/errors-and-limits.md",
    "route": "errors-and-limits",
    "label": "Errors and limits"
  },
  {
    "src": "docs/README.md",
    "route": "guide",
    "label": "Documentation map"
  },
  {
    "src": "STYLE.md",
    "route": "contributing/style-guide",
    "label": "Conventions"
  }
];
const item = (route) => ({ label: pages.find((p) => p.route === route).label, slug: route });
export const sidebar = [
  { label: "Start here", items: [item("overview"), item("install"), item("get-started/quickstart"), item("get-started/choose-an-id"), item("guide")] },
  { label: "Guides", items: [item("guides/primary-keys"), item("guides/timestamps")] },
  { label: "Reference", items: [item("reference/uuid"), item("reference/ksuid"), item("reference/timestamps"), item("errors-and-limits")] },
  { label: "Contributing", items: [item("contributing/style-guide")] }
];
