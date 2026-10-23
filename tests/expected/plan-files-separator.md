<!-- tf-plan-format -->
<details>
<summary>✅ <b>create</b> +1 ~0 −0</summary>

```diff
@@ ✅ terraform_data.foo-bar @@
+ id: (known after apply)
+ input: "foo"
+ output: (known after apply)
+ triggers_replace: null
```

</details>
<details>
<summary>🔄 <b>update</b> +0 ~1 −0</summary>

```diff
@@ 🔄 terraform_data.foo-bar @@
! input: "foo" -> "bar"
! output: "foo" -> (known after apply)
```

</details>

