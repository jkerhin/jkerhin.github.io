# jkerhin.github.io
Setting up a blog with GitHub Pages and Jekyll

# Blog
<!-- I could set up Jekyll locally and test first, but let's see if this works live! -->

<ul>
  {% for post in site.posts %}
    <li>
      <a href="{{ post.url }}">{{ post.title }}</a>
    </li>
  {% endfor %}
</ul>