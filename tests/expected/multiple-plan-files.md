<!-- tf-plan-format -->
<details>
<summary>✅ <b>create</b> +1 ~0 −0</summary>
<blockquote>
<details>
<summary>✅ <code>terraform_data.foo-bar</code>
</summary>

```
id: (known after apply)
input: "foo"
output: (known after apply)
triggers_replace: null
```

</details>
</blockquote>
</details>
<details>
<summary>✅🔄❌ <b>outputs</b> +0 ~1 −0</summary>
<blockquote>
<details>
<summary>🔄 <code>terraform_data.foo-bar</code>
</summary>

```
input: "foo" -> "bar"
output: "foo" -> (known after apply)
```

</details>
<details>
<summary>✅🔄❌ Outputs
</summary>

```
added: null -> "added"
changed: "before" -> "after"
removed: "removed" -> null
secret: sensitive -> sensitive (changed)
unknown: "foo" -> (known after apply)
```

</details>
</blockquote>
</details>
<details>
<summary>🔄 <b>update</b> +0 ~1 −0</summary>
<blockquote>
<details>
<summary>🔄 <code>terraform_data.foo-bar</code>
</summary>

```
input: "foo" -> "bar"
output: "foo" -> (known after apply)
```

</details>
</blockquote>
</details>

