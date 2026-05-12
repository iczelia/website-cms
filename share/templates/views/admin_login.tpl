<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>iczelia :: admin login</title>
<link rel="stylesheet" href="/cms.css">
</head>
<body class="cms-body cms-login-body">
<main class="cms-login">
  <h1>iczelia.cms</h1>
{% if error %}  <p class="cms-flash cms-flash-err">{{ error }}</p>
{% endif %}  <form method="POST" action="/admin/login">
    <input type="hidden" name="csrf" value="{{ csrf }}">
    <p><label>username<br><input name="username" autocomplete="username" required></label></p>
    <p><label>password<br><input type="password" name="password" autocomplete="current-password" required></label></p>
    <p><button type="submit">log in</button></p>
  </form>
</main>
</body>
</html>
