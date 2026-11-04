# Update models

Write a new model when your authorization rules change. Existing models remain available by ID.

This example continues [Check and list access](checks.md). It uses the original model JSON and `model_id` / `modelId` from [Define an authorization model](models.md). Run it after the earlier walkthrough because it changes the default model.

## Change the model

Models are immutable. Write a new model, and it becomes the latest model. You can still evaluate an older model by passing its ID.

Tuples do not belong to a model. When a new model does not accept a tuple, the extension keeps the tuple and ignores it in checks. You can still read and delete it. This example removes `blocked` and `can_view`:

```js tab="JavaScript"
const modelV2 = structuredClone(model)
const documentType = modelV2.type_definitions[3]
for (const name of ['blocked', 'can_view']) {
  delete documentType.relations[name]
  delete documentType.metadata.relations[name]
}
const v2 = await permissions.fga.admin.writeAuthorizationModel(modelV2)
if (v2.error) throw v2.error

const gone = await permissions.fga.admin.check({
  user: 'user:carl',
  relation: 'can_view',
  object: 'document:roadmap',
})
// gone.error.message:
//   relation 'document#can_view' not found
// gone.error.details: openfga:2000 validation_error
const old = await permissions.fga.admin.check({
  user: 'user:carl',
  relation: 'can_view',
  object: 'document:roadmap',
  authorizationModelId: modelId,
})
// old.data: false: the old model
const blocked = await permissions.fga.admin.read({
  object: 'document:roadmap',
  relation: 'blocked',
})
// blocked.data.tuples.length: 1: the tuple is still there
```

```sql tab="SQL"
select permissions.fga_write_authorization_model(
  model => jsonb_set(
    :'model'::jsonb,
    '{type_definitions,3}',
    (:'model'::jsonb #> '{type_definitions,3}')
      #- '{relations,blocked}'
      #- '{relations,can_view}'
      #- '{metadata,relations,blocked}'
      #- '{metadata,relations,can_view}'
  )
) as model_v2 \gset

select permissions.fga_check(
  subject => 'user:carl',
  relation => 'can_view',
  object => 'document:roadmap'
);
-- ERROR:  relation 'document#can_view' not found
-- DETAIL:  openfga:2000 validation_error
select permissions.fga_check(
  subject => 'user:carl',
  relation => 'can_view',
  object => 'document:roadmap',
  model_id => :'model_id'
);
-- false: the old model
select jsonb_array_length(tuples)
from permissions.fga_read(
  object => 'document:roadmap',
  relation => 'blocked'
);
-- 1: the tuple is still there
```

In practice, edit `model.fga` and transform it again. To remove every model and every tuple, call `fga_delete_store()`.
