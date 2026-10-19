<!-- tf-plan-format -->
<details>
<summary>✅create - Plan: 1 to add, 0 to change, 0 to destroy</summary>
<details>
<summary>✅terraform_data.foo-bar
</summary>

```
id: (known after apply)
input: "foo"
output: (known after apply)
triggers_replace: null
```

</details>
</details>
<details>
<summary>✅🔄❌outputs - Plan: 0 to add, 1 to change, 0 to destroy</summary>
<details>
<summary>🔄terraform_data.foo-bar
</summary>

```
input: "foo" -> "bar"
output: "foo" -> (known after apply)
```

</details>
<details>
<summary>✅🔄❌Outputs
</summary>

```
added: null -> "added"
changed: "before" -> "after"
removed: "removed" -> null
secret: sensitive -> sensitive (changed)
unknown: "foo" -> (known after apply)
```

</details>
</details>
<details>
<summary>🔄update - Plan: 0 to add, 1 to change, 0 to destroy</summary>
<details>
<summary>🔄terraform_data.foo-bar
</summary>

```
input: "foo" -> "bar"
output: "foo" -> (known after apply)
```

</details>
</details>

