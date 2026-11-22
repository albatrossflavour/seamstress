# webapp

Runs the example web application behind a **systemd** unit. See [the docs](https://docs.example.com/webapp) or `webapp::vhost`.

<script>alert('readme xss')</script>
<img src="https://tracker.example.com/pixel.gif" onerror="alert(1)">
[click me](javascript:alert('link xss'))
<!-- a hidden comment -->

## Usage

```puppet
class { 'webapp':
  port    => 8080,
  workers => 4,
}
```

| Setting | Default |
| --- | --- |
| `port` | 8080 |
| `workers` | 2 |

- one
- two with `code`
  - nested

> A quote.
