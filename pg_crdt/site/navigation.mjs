// Canonical pages. Consolidated routes redirect to their new home.
export const pages = [
  {
    "src": "docs/overview.md",
    "route": "overview",
    "label": "What is a CRDT?"
  },
  {
    "src": "docs/install.md",
    "route": "install",
    "label": "Install"
  },
  {
    "src": "docs/get-started/quickstart.md",
    "route": "get-started/quickstart",
    "label": "Try a counter"
  },
  {
    "src": "docs/get-started/text.md",
    "route": "get-started/text",
    "label": "Try shared text"
  },
  {
    "src": "docs/guides/app.md",
    "route": "guides/app",
    "label": "Application principles"
  },
  {
    "src": "docs/reference/application.md",
    "route": "reference/application",
    "label": "Application examples"
  },
  {
    "src": "docs/reference/pn.md",
    "route": "reference/pn",
    "label": "PN-Counter"
  },
  {
    "src": "docs/reference/yseq.md",
    "route": "reference/yseq",
    "label": "yseq_"
  },
  {
    "src": "docs/reference/shared.md",
    "route": "reference/shared",
    "label": "Identity settings"
  },
  {
    "src": "docs/reference/storage.md",
    "route": "reference/storage",
    "label": "Storage and limits"
  },
  {
    "src": "docs/reference/limits.md",
    "route": "reference/limits",
    "label": "Numeric limits"
  },
  {
    "src": "docs/reference/errors.md",
    "route": "reference/errors",
    "label": "Errors"
  },
  {
    "src": "docs/reference/operations.md",
    "route": "reference/operations",
    "label": "Operations"
  },
  {
    "src": "docs/reference/installation.md",
    "route": "reference/installation",
    "label": "Installation options"
  },
  {
    "src": "CHANGELOG.md",
    "route": "changelog",
    "label": "Changelog"
  },
  {
    "src": "test/README.md",
    "route": "contributing/test-suite",
    "label": "Tests"
  },
  {
    "src": "STYLE.md",
    "route": "contributing/style-guide",
    "label": "Writing conventions"
  },
  {
    "src": "docs/README.md",
    "route": "guide",
    "label": "Documentation"
  }
];

export const redirectPages = [
  {
    "src": "docs/guides/sync-counts.md",
    "route": "guides/sync-counts",
    "to": "get-started/quickstart",
    "hash": "add-an-offline-devices-count"
  },
  {
    "src": "docs/guides/replicas-and-identity.md",
    "route": "guides/replicas-and-identity",
    "to": "reference/shared",
    "hash": "replica-ids-and-entry-keys"
  },
  {
    "src": "docs/guides/security.md",
    "route": "guides/security",
    "to": "reference/application",
    "hash": "counters"
  },
  {
    "src": "docs/guides/storage-and-performance.md",
    "route": "guides/storage-and-performance",
    "to": "reference/storage",
    "hash": "counters"
  },
  {
    "src": "docs/text/forms.md",
    "route": "text/forms",
    "to": "reference/application",
    "hash": "forms"
  },
  {
    "src": "docs/text/access.md",
    "route": "text/access",
    "to": "reference/application",
    "hash": "forms"
  },
  {
    "src": "docs/text/live-editor.md",
    "route": "text/live-editor",
    "to": "reference/application",
    "hash": "live-editors"
  },
  {
    "src": "docs/text/search.md",
    "route": "text/search",
    "to": "reference/storage",
    "hash": "indexes-and-search"
  },
  {
    "src": "docs/text/limits.md",
    "route": "text/limits",
    "to": "reference/storage",
    "hash": "text"
  },
  {
    "src": "docs/operations/backups.md",
    "route": "operations/backups",
    "to": "reference/operations",
    "hash": "backups"
  },
  {
    "src": "docs/operations/maintenance.md",
    "route": "operations/maintenance",
    "to": "reference/storage",
    "hash": ""
  },
  {
    "src": "docs/guides/safe-updates.md",
    "route": "guides/safe-updates",
    "to": "reference/application",
    "hash": "updates-and-retries"
  },
  {
    "src": "docs/operations/troubleshooting.md",
    "route": "operations/troubleshooting",
    "to": "reference/operations",
    "hash": "troubleshooting"
  },
  {
    "src": "docs/operations/uninstall.md",
    "route": "operations/uninstall",
    "to": "reference/operations",
    "hash": "uninstall"
  },
  {
    "src": "docs/types/pn-counter.md",
    "route": "types/pn-counter",
    "to": "reference/pn",
    "hash": "state-and-merge"
  },
  {
    "src": "docs/types/collaborative-text.md",
    "route": "types/collaborative-text",
    "to": "reference/yseq",
    "hash": "operations"
  },
  {
    "src": "docs/guides/collaborative-text.md",
    "route": "guides/collaborative-text",
    "to": "reference/application",
    "hash": "forms"
  }
];

export const sidebar = [
  {
    "label": "Overview",
    "items": [
      {
        "label": "What is a CRDT?",
        "slug": "overview"
      },
      {
        "label": "Install",
        "slug": "install"
      },
      {
        "label": "Try a counter",
        "slug": "get-started/quickstart"
      },
      {
        "label": "Try shared text",
        "slug": "get-started/text"
      },
      {
        "label": "Application principles",
        "slug": "guides/app"
      }
    ]
  },
  {
    "label": "Guides",
    "collapsed": true,
    "items": [
      {
        "label": "Application examples",
        "slug": "reference/application"
      },
      {
        "label": "Identity settings",
        "slug": "reference/shared"
      },
      {
        "label": "Storage and limits",
        "slug": "reference/storage"
      },
      {
        "label": "Numeric limits",
        "slug": "reference/limits"
      },
      {
        "label": "Operations",
        "slug": "reference/operations"
      },
      {
        "label": "Installation options",
        "slug": "reference/installation"
      }
    ]
  },
  {
    "label": "Reference",
    "collapsed": true,
    "items": [
      {
        "label": "PN-Counter",
        "slug": "reference/pn"
      },
      {
        "label": "yseq_",
        "slug": "reference/yseq"
      },
      {
        "label": "Errors",
        "slug": "reference/errors"
      }
    ]
  },
  {
    "label": "Project",
    "collapsed": true,
    "items": [
      {
        "label": "Changelog",
        "slug": "changelog"
      },
      {
        "label": "Tests",
        "slug": "contributing/test-suite"
      },
      {
        "label": "Writing conventions",
        "slug": "contributing/style-guide"
      }
    ]
  }
];
