# 学校适配器契约（草案）

学校适配器只描述学校门户的差异，不能改变通用核心的安全边界。

```yaml
id: example-campus
display_name: Example Campus
ssid_patterns:
  - "Example-WiFi"
portal:
  discovery: http_redirect
  login_url: "https://portal.example.edu/login"
  mode: browser_assisted
fields:
  username: username
  password: password
  operator: operator
operator:
  required: false
  values: []
success:
  probe_url: "http://www.msftconnecttest.com/connecttest.txt"
  expected_body: "Microsoft Connect Test"
```

这个文件是配置形状示例，不是可用的学校配置。真实适配器必须以实际门户响应、表单字段和登录结果为依据，禁止凭字段名猜测协议。

适配器不得记录密码或完整 Cookie；遇到验证码、二次认证或不稳定的前端签名时，应返回浏览器辅助模式。
