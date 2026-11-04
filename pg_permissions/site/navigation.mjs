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
    "label": "Quickstart: check permissions"
  },
  {
    "src": "docs/get-started/choose-a-model.md",
    "route": "get-started/choose-a-model",
    "label": "Choose a permission model"
  },
  {
    "src": "docs/integrations/checks.md",
    "route": "integrations/checks",
    "label": "Check access in your application"
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
    "label": "Condition evaluation and context"
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
    "src": "docs/models/cedar/overview.md",
    "route": "models/cedar/overview",
    "label": "Overview"
  },
  {
    "src": "docs/models/cedar/policies.md",
    "route": "models/cedar/policies",
    "label": "Write policies"
  },
  {
    "src": "docs/models/cedar/entities.md",
    "route": "models/cedar/entities",
    "label": "Store entities"
  },
  {
    "src": "docs/models/cedar/templates.md",
    "route": "models/cedar/templates",
    "label": "Use policy templates"
  },
  {
    "src": "docs/models/cedar/checks.md",
    "route": "models/cedar/checks",
    "label": "Check access"
  },
  {
    "src": "docs/models/cedar/extensions.md",
    "route": "models/cedar/extensions",
    "label": "Extension types"
  },
  {
    "src": "docs/models/cedar/compatibility.md",
    "route": "models/cedar/compatibility",
    "label": "Cedar compatibility"
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
    "src": "docs/reference/cedar.md",
    "route": "reference/cedar",
    "label": "Cedar functions"
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
    "src": "docs/benchmarks.md",
    "route": "benchmarks",
    "label": "Benchmarks"
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
        "label": "Quickstart: check permissions",
        "slug": "get-started/quickstart"
      },
      {
        "label": "Choose a permission model",
        "slug": "get-started/choose-a-model"
      },
      {
        "label": "Benchmarks",
        "slug": "benchmarks"
      },
    ]
  },
  {
    "label": "Connect your application",
    "collapsed": true,
    "items": [
      {
        "label": "Check access in your application",
        "slug": "integrations/checks"
      },
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
            "label": "Condition evaluation and context",
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
      },
      {
        "label": "Policies (Cedar)",
        "collapsed": true,
        "items": [
          {
            "label": "Overview",
            "slug": "models/cedar/overview"
          },
          {
            "label": "Write policies",
            "slug": "models/cedar/policies"
          },
          {
            "label": "Store entities",
            "slug": "models/cedar/entities"
          },
          {
            "label": "Use policy templates",
            "slug": "models/cedar/templates"
          },
          {
            "label": "Check access",
            "slug": "models/cedar/checks"
          },
          {
            "label": "Extension types",
            "slug": "models/cedar/extensions"
          },
          {
            "label": "Cedar compatibility",
            "slug": "models/cedar/compatibility"
          }
        ]
      }
    ]
  },
  {
    "label": "Optional: enforce access with RLS",
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
          },
          {
            "label": "Cedar functions",
            "slug": "reference/cedar"
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
