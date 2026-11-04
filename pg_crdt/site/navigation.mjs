// Canonical page inventory. Sync, sidebar, and Markdown exports use this list.
// `src` is relative to pg_crdt/; `route` is the site path.
export const pages = [
  { src: 'docs/overview.md', route: 'overview', label: 'Overview' },
  { src: 'docs/README.md', route: 'guide', label: 'Documentation map' },
  { src: 'docs/install.md', route: 'install', label: 'Install' },
  { src: 'docs/get-started/quickstart.md', route: 'get-started/quickstart', label: 'Quickstart: a counter column' },
  { src: 'docs/guides/replicas-and-identity.md', route: 'guides/replicas-and-identity', label: 'Replicas and identity' },
  { src: 'docs/guides/safe-updates.md', route: 'guides/safe-updates', label: 'Update safely' },
  { src: 'docs/guides/security.md', route: 'guides/security', label: 'Accept writes from untrusted clients' },
  { src: 'docs/guides/storage-and-performance.md', route: 'guides/storage-and-performance', label: 'Storage and performance' },
  { src: 'docs/guides/collaborative-text.md', route: 'guides/collaborative-text', label: 'Collaborative text for a blog post' },
  { src: 'docs/types/pn-counter.md', route: 'types/pn-counter', label: 'PN-Counter' },
  { src: 'docs/types/collaborative-text.md', route: 'types/collaborative-text', label: 'Collaborative text' },
  { src: 'docs/reference/shared.md', route: 'reference/shared', label: 'Shared' },
  { src: 'docs/reference/pn.md', route: 'reference/pn', label: 'PN-Counter functions' },
  { src: 'docs/reference/ydoc.md', route: 'reference/ydoc', label: 'Collaborative text functions' },
  { src: 'docs/reference/errors.md', route: 'reference/errors', label: 'Errors' },
  { src: 'docs/reference/limits.md', route: 'reference/limits', label: 'Limits' },
  { src: 'CHANGELOG.md', route: 'changelog', label: 'Changelog' },
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
      item('guides/replicas-and-identity'),
      item('guides/safe-updates'),
      item('guides/security'),
      item('guides/storage-and-performance'),
      item('guides/collaborative-text'),
    ],
  },
  {
    label: 'Types',
    items: [item('types/pn-counter'), item('types/collaborative-text')],
  },
  {
    label: 'Reference',
    items: [
      item('reference/shared'),
      item('reference/pn'),
      item('reference/ydoc'),
      item('reference/errors'),
      item('reference/limits'),
    ],
  },
  {
    label: 'Project',
    items: [item('changelog')],
  },
  {
    label: 'Contributing',
    collapsed: true,
    items: [item('contributing/test-suite'), item('contributing/style-guide')],
  },
];
