// Canonical Markdown sources and routes. Legacy routes remain published outside the sidebar.
export const pages = [
  {
    "src": "docs/overview.md",
    "route": "overview",
    "label": "What pg_crdt does"
  },
  {
    "src": "docs/install.md",
    "route": "install",
    "label": "Install"
  },
  {
    "src": "docs/get-started/quickstart.md",
    "route": "get-started/quickstart",
    "label": "Your first counter"
  },
  {
    "src": "docs/guides/sync-counts.md",
    "route": "guides/sync-counts",
    "label": "Sync counts from another device"
  },
  {
    "src": "docs/guides/replicas-and-identity.md",
    "route": "guides/replicas-and-identity",
    "label": "Identify writers and devices"
  },
  {
    "src": "docs/guides/security.md",
    "route": "guides/security",
    "label": "Accept client updates"
  },
  {
    "src": "docs/guides/storage-and-performance.md",
    "route": "guides/storage-and-performance",
    "label": "Store and query large counters"
  },
  {
    "src": "docs/get-started/text.md",
    "route": "get-started/text",
    "label": "Your first shared document"
  },
  {
    "src": "docs/text/forms.md",
    "route": "text/forms",
    "label": "Save changes from a form"
  },
  {
    "src": "docs/text/access.md",
    "route": "text/access",
    "label": "Control document access"
  },
  {
    "src": "docs/text/live-editor.md",
    "route": "text/live-editor",
    "label": "Connect a live editor"
  },
  {
    "src": "docs/text/search.md",
    "route": "text/search",
    "label": "Search documents"
  },
  {
    "src": "docs/text/limits.md",
    "route": "text/limits",
    "label": "Limits and performance"
  },
  {
    "src": "docs/operations/backups.md",
    "route": "operations/backups",
    "label": "Back up and restore"
  },
  {
    "src": "docs/operations/maintenance.md",
    "route": "operations/maintenance",
    "label": "Maintain storage"
  },
  {
    "src": "docs/guides/safe-updates.md",
    "route": "guides/safe-updates",
    "label": "Safe updates and retries"
  },
  {
    "src": "docs/operations/troubleshooting.md",
    "route": "operations/troubleshooting",
    "label": "Troubleshooting"
  },
  {
    "src": "docs/operations/uninstall.md",
    "route": "operations/uninstall",
    "label": "Uninstall"
  },
  {
    "src": "docs/types/pn-counter.md",
    "route": "types/pn-counter",
    "label": "How counters merge"
  },
  {
    "src": "docs/types/collaborative-text.md",
    "route": "types/collaborative-text",
    "label": "How text merges"
  },
  {
    "src": "docs/reference/pn.md",
    "route": "reference/pn",
    "label": "Counter SQL functions"
  },
  {
    "src": "docs/reference/yseq.md",
    "route": "reference/yseq",
    "label": "Text column SQL functions"
  },
  {
    "src": "docs/reference/shared.md",
    "route": "reference/shared",
    "label": "Identity settings"
  },
  {
    "src": "docs/reference/errors.md",
    "route": "reference/errors",
    "label": "Errors"
  },
  {
    "src": "docs/reference/limits.md",
    "route": "reference/limits",
    "label": "Limits"
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
    "label": "Documentation map"
  },
  {
    "src": "docs/guides/collaborative-text.md",
    "route": "guides/collaborative-text",
    "label": "Build with collaborative text"
  },
  {
    "src": "docs/reference/ydoc.md",
    "route": "reference/ydoc",
    "label": "Table-backed documents: archived"
  },
  {
    "src": "docs/reference/client.md",
    "route": "reference/client",
    "label": "JavaScript client: archived"
  }
];

export const sidebar = [
  {
    "label": "Start here",
    "items": [
      {
        "label": "What pg_crdt does",
        "slug": "overview"
      },
      {
        "label": "Install",
        "slug": "install"
      }
    ]
  },
  {
    "label": "Counters",
    "items": [
      {
        "label": "Your first counter",
        "slug": "get-started/quickstart"
      },
      {
        "label": "Sync counts from another device",
        "slug": "guides/sync-counts"
      },
      {
        "label": "Identify writers and devices",
        "slug": "guides/replicas-and-identity"
      },
      {
        "label": "Accept client updates",
        "slug": "guides/security"
      },
      {
        "label": "Store and query large counters",
        "slug": "guides/storage-and-performance"
      }
    ]
  },
  {
    "label": "Collaborative text",
    "items": [
      {
        "label": "Your first shared document",
        "slug": "get-started/text"
      },
      {
        "label": "Save changes from a form",
        "slug": "text/forms"
      },
      {
        "label": "Control document access",
        "slug": "text/access"
      },
      {
        "label": "Connect a live editor",
        "slug": "text/live-editor"
      },
      {
        "label": "Search documents",
        "slug": "text/search"
      },
      {
        "label": "Limits and performance",
        "slug": "text/limits"
      }
    ]
  },
  {
    "label": "Operate and troubleshoot",
    "items": [
      {
        "label": "Back up and restore",
        "slug": "operations/backups"
      },
      {
        "label": "Maintain storage",
        "slug": "operations/maintenance"
      },
      {
        "label": "Safe updates and retries",
        "slug": "guides/safe-updates"
      },
      {
        "label": "Troubleshooting",
        "slug": "operations/troubleshooting"
      },
      {
        "label": "Uninstall",
        "slug": "operations/uninstall"
      }
    ]
  },
  {
    "label": "How it works",
    "items": [
      {
        "label": "How counters merge",
        "slug": "types/pn-counter"
      },
      {
        "label": "How text merges",
        "slug": "types/collaborative-text"
      }
    ],
    "collapsed": true
  },
  {
    "label": "Reference",
    "items": [
      {
        "label": "Counter SQL functions",
        "slug": "reference/pn"
      },
      {
        "label": "Text column SQL functions",
        "slug": "reference/yseq"
      },
      {
        "label": "Identity settings",
        "slug": "reference/shared"
      },
      {
        "label": "Errors",
        "slug": "reference/errors"
      },
      {
        "label": "Limits",
        "slug": "reference/limits"
      }
    ],
    "collapsed": true
  },
  {
    "label": "Project",
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
    ],
    "collapsed": true
  }
];
