---
layout: home
permalink: /
---

# jkerhin.github.io
Setting up a blog with GitHub Pages and Jekyll

# Blog

<ul>
  {% for post in site.posts %}
    <li>
      <a href="{{ post.url }}">{{ post.title }}</a>
    </li>
  {% endfor %}
</ul>
