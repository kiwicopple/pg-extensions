// Canonical page inventory. Sync, sidebar, and Markdown exports use this list.
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
    "label": "Quickstart: protect a table"
  },
  {
    "src": "docs/get-started/choose-a-model.md",
    "route": "get-started/choose-a-model",
    "label": "Choose a permission model"
  },
  {
    "src": "docs/integrations/identity.md",
    "route": "integrations/identity",
    "label": "Identity and request context"
  },
  {
    "src": "docs/integrations/javascript.md",
    "route": "integrations/javascript",
    "label": "JavaScript setup"
  },
  {
    "src": "docs/integrations/privileges.md",
    "route": "integrations/privileges",
    "label": "Client and admin privileges"
  },
  {
    "src": "docs/integrations/cleanup.md",
    "route": "integrations/cleanup",
    "label": "Delete users and clean up permissions"
  },
  {
    "src": "docs/models/rbac/overview.md",
    "route": "models/rbac/overview",
    "label": "Overview"
  },
  {
    "src": "docs/models/rbac/app-wide.md",
    "route": "models/rbac/app-wide",
    "label": "App-wide roles"
  },
  {
    "src": "docs/models/rbac/tenants.md",
    "route": "models/rbac/tenants",
    "label": "Tenant-scoped roles"
  },
  {
    "src": "docs/models/rbac/manage.md",
    "route": "models/rbac/manage",
    "label": "Manage roles and assignments"
  },
  {
    "src": "docs/models/openfga/overview.md",
    "route": "models/openfga/overview",
    "label": "Overview"
  },
  {
    "src": "docs/models/openfga/models.md",
    "route": "models/openfga/models",
    "label": "Define an authorization model"
  },
  {
    "src": "docs/models/openfga/tuples.md",
    "route": "models/openfga/tuples",
    "label": "Share objects and manage tuples"
  },
  {
    "src": "docs/models/openfga/checks.md",
    "route": "models/openfga/checks",
    "label": "Check and list access"
  },
  {
    "src": "docs/models/openfga/conditions.md",
    "route": "models/openfga/conditions",
    "label": "Conditions and request context"
  },
  {
    "src": "docs/models/openfga/condition-examples.md",
    "route": "models/openfga/condition-examples",
    "label": "Expiry and conditional shares"
  },
  {
    "src": "docs/models/openfga/condition-behavior.md",
    "route": "models/openfga/condition-behavior",
    "label": "Condition evaluation and RLS"
  },
  {
    "src": "docs/models/openfga/update-models.md",
    "route": "models/openfga/update-models",
    "label": "Update models"
  },
  {
    "src": "docs/models/openfga/compatibility.md",
    "route": "models/openfga/compatibility",
    "label": "OpenFGA compatibility"
  },
  {
    "src": "docs/rls/policies.md",
    "route": "rls/policies",
    "label": "Read and write policies"
  },
  {
    "src": "docs/rls/combine-models.md",
    "route": "rls/combine-models",
    "label": "Combine permission models"
  },
  {
    "src": "docs/rls/denies-and-context.md",
    "route": "rls/denies-and-context",
    "label": "Denies, row attributes, and trusted context"
  },
  {
    "src": "docs/rls/performance.md",
    "route": "rls/performance",
    "label": "Performance and query plans"
  },
  {
    "src": "docs/reference/shared.md",
    "route": "reference/shared",
    "label": "Shared functions"
  },
  {
    "src": "docs/reference/rbac.md",
    "route": "reference/rbac",
    "label": "RBAC functions"
  },
  {
    "src": "docs/reference/openfga.md",
    "route": "reference/openfga",
    "label": "OpenFGA functions"
  },
  {
    "src": "docs/reference/javascript.md",
    "route": "reference/javascript",
    "label": "JavaScript client"
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
    "src": "docs/reference/cel.md",
    "route": "reference/cel",
    "label": "CEL support"
  },
  {
    "src": "research/README.md",
    "route": "research/overview",
    "label": "Overview"
  },
  {
    "src": "research/architecture.md",
    "route": "research/architecture",
    "label": "Current architecture"
  },
  {
    "src": "research/benchmarks/README.md",
    "route": "research/benchmarks/overview",
    "label": "Overview"
  },
  {
    "src": "research/benchmarks/D.md",
    "route": "research/benchmarks/design-d-report",
    "label": "Current implementation"
  },
  {
    "src": "research/benchmarks/COMPARISON.md",
    "route": "research/benchmarks/comparison",
    "label": "Earlier engine comparison"
  },
  {
    "src": "research/benchmarks/VERSIONS.md",
    "route": "research/benchmarks/versions-report",
    "label": "Version measurements"
  },
  {
    "src": "research/benchmarks/OPTIMIZATIONS.md",
    "route": "research/benchmarks/optimizations-report",
    "label": "Optimization report"
  },
  {
    "src": "research/decision.md",
    "route": "research/decision",
    "label": "Decision record"
  },
  {
    "src": "research/designs/d-per-model.md",
    "route": "research/designs/d-per-model",
    "label": "Per-model implementation"
  },
  {
    "src": "research/designs/d-conditions.md",
    "route": "research/designs/d-conditions",
    "label": "Condition evaluator"
  },
  {
    "src": "research/goals.md",
    "route": "research/goals",
    "label": "Goals and budgets"
  },
  {
    "src": "research/plan.md",
    "route": "research/plan",
    "label": "Completed implementation plan"
  },
  {
    "src": "research/prototypes/README.md",
    "route": "research/prototypes/overview",
    "label": "Overview"
  },
  {
    "src": "research/designs/a-tuple-core.md",
    "route": "research/designs/a-tuple-core",
    "label": "A: tuple core"
  },
  {
    "src": "research/designs/b-policy-first.md",
    "route": "research/designs/b-policy-first",
    "label": "B: policy first"
  },
  {
    "src": "research/designs/c-compiled-model.md",
    "route": "research/designs/c-compiled-model",
    "label": "C: compiled model"
  },
  {
    "src": "research/prototypes/a-tuple-core.md",
    "route": "research/prototypes/a-tuple-core",
    "label": "A: usage"
  },
  {
    "src": "research/prototypes/b-policy-first.md",
    "route": "research/prototypes/b-policy-first",
    "label": "B: usage"
  },
  {
    "src": "research/prototypes/c-compiled-model.md",
    "route": "research/prototypes/c-compiled-model",
    "label": "C: usage"
  },
  {
    "src": "research/upstream/openfga-cycle-but-not-inconsistency.md",
    "route": "research/upstream/openfga-cycle-but-not",
    "label": "OpenFGA upstream report"
  },
  {
    "src": "research/journal.md",
    "route": "research/journal",
    "label": "Build journal"
  },
  {
    "src": "test/README.md",
    "route": "contributing/test-suite",
    "label": "Tests and benchmark harness"
  },
  {
    "src": "STYLE.md",
    "route": "contributing/style-guide",
    "label": "Documentation conventions"
  },
  {
    "src": "docs/README.md",
    "route": "guide",
    "label": "Documentation map"
  },
  {
    "src": "docs/rbac.md",
    "route": "rbac",
    "label": "Moved: rbac",
    "legacy": true
  },
  {
    "src": "docs/fga.md",
    "route": "fga",
    "label": "Moved: fga",
    "legacy": true
  },
  {
    "src": "docs/conditions.md",
    "route": "conditions",
    "label": "Moved: conditions",
    "legacy": true
  },
  {
    "src": "docs/rls.md",
    "route": "rls",
    "label": "Moved: rls",
    "legacy": true
  },
  {
    "src": "docs/reference.md",
    "route": "reference",
    "label": "Moved: reference",
    "legacy": true
  },
  {
    "src": "docs/errors-and-limits.md",
    "route": "errors-and-limits",
    "label": "Moved: errors-and-limits",
    "legacy": true
  },
  {
    "src": "docs/javascript.md",
    "route": "javascript",
    "label": "Moved: javascript",
    "legacy": true
  }
];

export const sidebar = [
  {
    "label": "Overview",
    "slug": "overview"
  },
  {
    "label": "Get started",
    "collapsed": false,
    "items": [
      {
        "label": "Install",
        "slug": "install"
      },
      {
        "label": "Quickstart: protect a table",
        "slug": "get-started/quickstart"
      },
      {
        "label": "Choose a permission model",
        "slug": "get-started/choose-a-model"
      }
    ]
  },
  {
    "label": "Connect your application",
    "collapsed": true,
    "items": [
      {
        "label": "Identity and request context",
        "slug": "integrations/identity"
      },
      {
        "label": "JavaScript setup",
        "slug": "integrations/javascript"
      },
      {
        "label": "Client and admin privileges",
        "slug": "integrations/privileges"
      },
      {
        "label": "Delete users and clean up permissions",
        "slug": "integrations/cleanup"
      }
    ]
  },
  {
    "label": "Permission models",
    "collapsed": false,
    "items": [
      {
        "label": "Roles and permissions (RBAC)",
        "collapsed": true,
        "items": [
          {
            "label": "Overview",
            "slug": "models/rbac/overview"
          },
          {
            "label": "App-wide roles",
            "slug": "models/rbac/app-wide"
          },
          {
            "label": "Tenant-scoped roles",
            "slug": "models/rbac/tenants"
          },
          {
            "label": "Manage roles and assignments",
            "slug": "models/rbac/manage"
          }
        ]
      },
      {
        "label": "Relationships (OpenFGA)",
        "collapsed": true,
        "items": [
          {
            "label": "Overview",
            "slug": "models/openfga/overview"
          },
          {
            "label": "Define an authorization model",
            "slug": "models/openfga/models"
          },
          {
            "label": "Share objects and manage tuples",
            "slug": "models/openfga/tuples"
          },
          {
            "label": "Check and list access",
            "slug": "models/openfga/checks"
          },
          {
            "label": "Conditions and request context",
            "slug": "models/openfga/conditions"
          },
          {
            "label": "Expiry and conditional shares",
            "slug": "models/openfga/condition-examples"
          },
          {
            "label": "Condition evaluation and RLS",
            "slug": "models/openfga/condition-behavior"
          },
          {
            "label": "Update models",
            "slug": "models/openfga/update-models"
          },
          {
            "label": "OpenFGA compatibility",
            "slug": "models/openfga/compatibility"
          }
        ]
      }
    ]
  },
  {
    "label": "Enforce access with RLS",
    "collapsed": true,
    "items": [
      {
        "label": "Read and write policies",
        "slug": "rls/policies"
      },
      {
        "label": "Combine permission models",
        "slug": "rls/combine-models"
      },
      {
        "label": "Denies, row attributes, and trusted context",
        "slug": "rls/denies-and-context"
      },
      {
        "label": "Performance and query plans",
        "slug": "rls/performance"
      }
    ]
  },
  {
    "label": "Reference",
    "collapsed": true,
    "items": [
      {
        "label": "SQL functions",
        "collapsed": true,
        "items": [
          {
            "label": "Shared functions",
            "slug": "reference/shared"
          },
          {
            "label": "RBAC functions",
            "slug": "reference/rbac"
          },
          {
            "label": "OpenFGA functions",
            "slug": "reference/openfga"
          }
        ]
      },
      {
        "label": "JavaScript client",
        "slug": "reference/javascript"
      },
      {
        "label": "Errors",
        "slug": "reference/errors"
      },
      {
        "label": "Limits",
        "slug": "reference/limits"
      },
      {
        "label": "CEL support",
        "slug": "reference/cel"
      }
    ]
  },
  {
    "label": "Research and design",
    "collapsed": true,
    "items": [
      {
        "label": "Overview",
        "slug": "research/overview"
      },
      {
        "label": "Current architecture",
        "slug": "research/architecture"
      },
      {
        "label": "Benchmarks",
        "collapsed": true,
        "items": [
          {
            "label": "Overview",
            "slug": "research/benchmarks/overview"
          },
          {
            "label": "Current implementation",
            "slug": "research/benchmarks/design-d-report"
          },
          {
            "label": "Comparison dashboard",
            "slug": "research/benchmarks/dashboard"
          },
          {
            "label": "Optimizations",
            "slug": "research/benchmarks/optimizations"
          },
          {
            "label": "Postgres versions",
            "slug": "research/benchmarks/postgres-versions"
          },
          {
            "label": "Earlier engine comparison",
            "slug": "research/benchmarks/comparison"
          },
          {
            "label": "Version measurements",
            "slug": "research/benchmarks/versions-report"
          },
          {
            "label": "Optimization report",
            "slug": "research/benchmarks/optimizations-report"
          }
        ]
      },
      {
        "label": "Design decisions",
        "collapsed": true,
        "items": [
          {
            "label": "Decision record",
            "slug": "research/decision"
          },
          {
            "label": "Per-model implementation",
            "slug": "research/designs/d-per-model"
          },
          {
            "label": "Condition evaluator",
            "slug": "research/designs/d-conditions"
          },
          {
            "label": "Goals and budgets",
            "slug": "research/goals"
          },
          {
            "label": "Completed implementation plan",
            "slug": "research/plan"
          }
        ]
      },
      {
        "label": "Historical designs and prototypes",
        "collapsed": true,
        "items": [
          { "label": "Prototype comparison", "slug": "research/prototypes-comparison" },
          {
            "label": "Overview",
            "slug": "research/prototypes/overview"
          },
          {
            "label": "A: tuple core",
            "slug": "research/designs/a-tuple-core"
          },
          {
            "label": "B: policy first",
            "slug": "research/designs/b-policy-first"
          },
          {
            "label": "C: compiled model",
            "slug": "research/designs/c-compiled-model"
          },
          {
            "label": "A: usage",
            "slug": "research/prototypes/a-tuple-core"
          },
          {
            "label": "B: usage",
            "slug": "research/prototypes/b-policy-first"
          },
          {
            "label": "C: usage",
            "slug": "research/prototypes/c-compiled-model"
          }
        ]
      },
      {
        "label": "OpenFGA upstream report",
        "slug": "research/upstream/openfga-cycle-but-not"
      },
      {
        "label": "Build journal",
        "slug": "research/journal"
      }
    ]
  },
  {
    "label": "Contributing",
    "collapsed": true,
    "items": [
      {
        "label": "Tests and benchmark harness",
        "slug": "contributing/test-suite"
      },
      {
        "label": "Documentation conventions",
        "slug": "contributing/style-guide"
      }
    ]
  }
];
