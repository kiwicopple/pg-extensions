// Canonical page inventory. Sync, sidebar, and Markdown exports use this list.
// `src` is relative to pg_validate/; `route` is the site path.
export const pages = [
  { src: 'docs/overview.md', route: 'overview', label: 'Overview' },
  { src: 'docs/README.md', route: 'guide', label: 'Documentation map' },
  { src: 'docs/install.md', route: 'install', label: 'Install' },
  { src: 'docs/get-started/quickstart.md', route: 'get-started/quickstart', label: 'Quickstart: validate a table' },
  { src: 'docs/guides/constraints.md', route: 'guides/constraints', label: 'Use validators in constraints' },
  { src: 'docs/guides/normalization.md', route: 'guides/normalization', label: 'Canonical forms and normalizing input' },
  { src: 'docs/registry.md', route: 'guides/custom-formats', label: 'Custom formats' },
  { src: 'docs/guides/named-schemas.md', route: 'guides/named-schemas', label: 'Named JSON schemas' },
  { src: 'docs/reference/identifiers.md', route: 'reference/identifiers', label: 'Identifiers' },
  { src: 'docs/reference/internet.md', route: 'reference/internet', label: 'Internet' },
  { src: 'docs/reference/dates.md', route: 'reference/dates', label: 'Dates and times' },
  { src: 'docs/reference/international.md', route: 'reference/international', label: 'International' },
  { src: 'docs/reference/developer.md', route: 'reference/developer', label: 'Developer formats' },
  { src: 'docs/reference/financial.md', route: 'reference/financial', label: 'Financial' },
  { src: 'docs/reference/registry.md', route: 'reference/registry', label: 'Registry functions' },
  { src: 'docs/errors-and-limits.md', route: 'reference/errors-and-limits', label: 'Errors and limits' },
  { src: 'docs/json-schema.md', route: 'reference/json-schema', label: 'JSON Schema' },
  { src: 'docs/roadmap.md', route: 'plans/roadmap', label: 'Roadmap' },
  { src: 'test/README.md', route: 'contributing/test-suite', label: 'Test suite' },
  { src: 'STYLE.md', route: 'contributing/style-guide', label: 'Conventions' },
];

const item = (route) => ({ label: pages.find((p) => p.route === route).label, slug: route });

export const sidebar = [
  {
    label: 'Start here',
    items: [item('overview'), item('install'), item('get-started/quickstart'), item('guide')],
  },
  {
    label: 'Guides',
    items: [
      item('guides/constraints'),
      item('guides/normalization'),
      item('guides/custom-formats'),
      item('guides/named-schemas'),
    ],
  },
  {
    label: 'Reference',
    items: [
      item('reference/identifiers'),
      item('reference/internet'),
      item('reference/dates'),
      item('reference/international'),
      item('reference/developer'),
      item('reference/financial'),
      item('reference/registry'),
      item('reference/json-schema'),
      item('reference/errors-and-limits'),
    ],
  },
  {
    label: 'Plans',
    items: [item('plans/roadmap')],
  },
  {
    label: 'Contributing',
    collapsed: true,
    items: [item('contributing/test-suite'), item('contributing/style-guide')],
  },
];
