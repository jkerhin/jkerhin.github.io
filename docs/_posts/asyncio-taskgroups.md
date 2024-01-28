---
layout: post
title: "Asyncio TaskGroups in Python"
permalink: /blog/asyncio-taskgroups
---

# Asyncio TaskGroups

TL;DR - `asyncio.TaskGroup()` was introduced in Python3.11. I think it's great and
recommend using it over `asyncio.gather()`

# The Background

I've been meaning to learn how to do async programming in Python for quite a while, but
thus far had never really had a compelling use case. I don't do any web programming at
work or at home, and the tools I'm currently involved with at work wouldn't benefit from
async.

Recently, however, I was doing some web scraping - one of the textbook use cases for async
programming. At a very high level, I wanted to pull data from an API and store it in a
database using `sqlalchemy`. I hadn't yet familiarized myself with the `sqlalchemy` 2.0
API, so I decided to teach myself two things at once.

To leverage the benefits of async, I created a `Worker` class that would interact with the
API and then store the results to the database. In the process of implementing the
`Worker`s, it finally clicked to me why `sqlalchemy` makes it so much easier to create a
session maker, rather than opening up a session directly. To keep objects in scope, each
`Worker` should have its own `Session` (well, `AsyncSession` in this case).

I've _vastly_ simplified the setup that I have, to provide a minimum reproducible example.
The following file sets up a `sqlalchemy` model and populates a `sqlite` database with a
few dummy posts.

```python
import asyncio

from sqlalchemy.ext.asyncio import (
    AsyncAttrs,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column

CONNECTION_STRING: str = "sqlite+aiosqlite:///posts.sqlite3"


class Base(AsyncAttrs, DeclarativeBase):
    pass


class Post(Base):
    __tablename__ = "post"
    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    url: Mapped[str]
    content: Mapped[str] = mapped_column(nullable=True)


async def async_main():
    engine = create_async_engine(CONNECTION_STRING)
    maker = async_sessionmaker(engine)

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    async with maker() as session:
        async with session.begin():
            session.add_all(
                [
                    Post(url="https://example.com/posts/post1"),
                    Post(url="https://example.com/posts/post2"),
                    Post(url="https://example.com/posts/post3"),
                ]
            )


if __name__ == "__main__":
    asyncio.run(async_main())
```

And this file is a vastly simplified subset of my script that was actually hitting the API
and processing the data. For ...architectural reasons that are likely due for a revisit,
each of the `Worker`s pulls post IDs off a shared queue, fetches the associated `Post`
from the database, processes the `Post`, and stores the processed data with a commit. When
one of the `Worker`s pulls is done pulling the last item from the queue, it sets the
`ALL_DONE` flag and all the workers terminate.

```python
import asyncio

from sqlalchemy import select
from sqlalchemy.ext.asyncio import (
    async_sessionmaker,
    create_async_engine,
)

from model_and_setup import Post, CONNECTION_STRING

ALL_DONE = asyncio.Event()


class Worker:
    def __init__(self, maker, queue):
        self.maker = maker
        self.queue = queue

    async def run(self):
        async with self.maker() as db_ses:
            while not ALL_DONE.is_set():
                post_id = await self.queue.get()
                q = select(Post).where(Post.id == post_id)

                post = await db_ses.scalar_one(q)
                await asyncio.sleep(1)  # Simulate API call
                post.content = "Some content!"
                await db_ses.commit()

                self.queue.task_done()
                if self.queue.empty():
                    ALL_DONE.set()


async def main():
    maker = async_sessionmaker(bind=create_async_engine(CONNECTION_STRING))
    queue = asyncio.Queue()
    ALL_DONE.clear()

    for post_id in range(1, 4):
        queue.put_nowait(post_id)

    # Spin up 3 workers
    tasks = []
    for _ in range(3):
        worker = Worker(maker=maker, queue=queue)
        task = asyncio.create_task(worker.run())
        tasks.append(task)

    await asyncio.gather(*tasks, return_exceptions=True)
    await ALL_DONE.wait()


if __name__ == "__main__":
    asyncio.run(main())
```

The workers are created and monitored in the `main()` function. A sequence of `Worker`
objects is created, and then `asyncio.create_task()` is used to create an async task for
the `Worker`'s `run()` function. The tasks are then awaited with `asyncio.gather()` and
the `main()` function waits for `ALL_DONE` to be set.

# The Problem

...Well that's the _intended_ behavior. In practice, if you run `asyncio_gather.py`
_nothing happens_. The script runs without complaint, but then just hangs indefinitely.
This wasn't entirely surprising to me as Python async was new to me, and it's famously
hard to debug. I assumed I had used an API incorrectly or forgotten to `await` a
coroutine.

I pushed `ctrl+c` to kill the script, expecting a stack trace to help give me a hint as to
where I made a mistake. Unfortunately...

```
Traceback (most recent call last):
  File "C:\Program Files\WindowsApps\PythonSoftwareFoundation.Python.3.12_3.12.496.0_x64__qbz5n2kfra8p0\Lib\asyncio\runners.py", line 118, in run
    return self._loop.run_until_complete(task)
           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "C:\Program Files\WindowsApps\PythonSoftwareFoundation.Python.3.12_3.12.496.0_x64__qbz5n2kfra8p0\Lib\asyncio\base_events.py", line 684, in run_until_complete
    return future.result()
           ^^^^^^^^^^^^^^^
  File "H:\projects\taskgroups-blog-post\asyncio_gather.py", line 52, in main
    await ALL_DONE.wait()
  File "C:\Program Files\WindowsApps\PythonSoftwareFoundation.Python.3.12_3.12.496.0_x64__qbz5n2kfra8p0\Lib\asyncio\locks.py", line 212, in wait
    await fut
asyncio.exceptions.CancelledError

During handling of the above exception, another exception occurred:

Traceback (most recent call last):
  File "H:\projects\taskgroups-blog-post\asyncio_gather.py", line 56, in <module>
    asyncio.run(main())
  File "C:\Program Files\WindowsApps\PythonSoftwareFoundation.Python.3.12_3.12.496.0_x64__qbz5n2kfra8p0\Lib\asyncio\runners.py", line 194, in run
    return runner.run(main)
           ^^^^^^^^^^^^^^^^
  File "C:\Program Files\WindowsApps\PythonSoftwareFoundation.Python.3.12_3.12.496.0_x64__qbz5n2kfra8p0\Lib\asyncio\runners.py", line 123, in run
    raise KeyboardInterrupt()
KeyboardInterrupt

Aborted!
```

Ok, sure, yes `KeyboardInterrupt()` was the cause of the crash. But that doesn't help me
debug my script at all! I was sure that something went wrong in the `Worker.run()`
function, so I started `print()` statement debugging. By doing a very rough "binary
search" of were to put `print()` statements, I was able to get here:

```python
# Inside Worker.run()
post_id = await self.queue.get()
print(f"Successfully got {post_id=} from queue")
q = select(Post).where(Post.id == post_id)

post = await db_ses.scalar_one(q)
print("Never reached!")
await asyncio.sleep(1)  # Simulate API call
```

Running the script with those lines added gives:
```
Successfully got post_id=1 from queue
Successfully got post_id=2 from queue
Successfully got post_id=3 from queue
```

Well now at least I knew where the error _was_ in the code, but I couldn't for the life of
me figure out _why_ it was happening. For those of you who've already spotted it, recall
that I was using this application as a way to learn the `sqlalchemy` 2.0 API, including
the now preferred `select` interface vs the `session.query()` interface.

# The Solution

I then spent a long time searching around for suggestions/tips on how to debug
"deadlocked" async Python code. I tried a number of approaches, but didn't make any
significant progress. I saw [in the docs](https://docs.python.org/3.12/library/asyncio-task.html#asyncio.gather)
that `TaskGroup`s were recommended as an alternative approach to `gather()`, and had
heard about them as a new feature in Python 3.11 in one of the podcasts I listen to. This
would have been from either [Talk Python](https://talkpython.fm/) or
[The Real Python Podcast](https://realpython.com/podcasts/rpp/) (both of which I strongly
recommend!).

With that in mind, I reworked the `main()` function of my app to use `TaskGroup`s instead
of calling `asyncio.gather()`:

```python
#...
# in main()
    async with asyncio.TaskGroup() as tg:
        # Spin up 3 workers
        tasks = []
        for _ in range(3):
            worker = Worker(maker=maker, queue=queue)
            task = tg.create_task(worker.run())
            tasks.append(task)

    await ALL_DONE.wait()
#...
```

After that very minimal update, I re-ran the new script and...

```
  + Exception Group Traceback (most recent call last):
  |   File "H:\projects\taskgroups-blog-post\taskgroups.py", line 56, in <module>
  |     asyncio.run(main())
  |   File "C:\Program Files\WindowsApps\PythonSoftwareFoundation.Python.3.12_3.12.496.0_x64__qbz5n2kfra8p0\Lib\asyncio\runners.py", line 194, in run
  |     return runner.run(main)
  |            ^^^^^^^^^^^^^^^^
  |   File "C:\Program Files\WindowsApps\PythonSoftwareFoundation.Python.3.12_3.12.496.0_x64__qbz5n2kfra8p0\Lib\asyncio\runners.py", line 118, in run
  |     return self._loop.run_until_complete(task)
  |            ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  |   File "C:\Program Files\WindowsApps\PythonSoftwareFoundation.Python.3.12_3.12.496.0_x64__qbz5n2kfra8p0\Lib\asyncio\base_events.py", line 684, in run_until_complete
  |     return future.result()
  |            ^^^^^^^^^^^^^^^
  |   File "H:\projects\taskgroups-blog-post\taskgroups.py", line 42, in main
  |     async with asyncio.TaskGroup() as tg:
  |   File "C:\Program Files\WindowsApps\PythonSoftwareFoundation.Python.3.12_3.12.496.0_x64__qbz5n2kfra8p0\Lib\asyncio\taskgroups.py", line 145, in __aexit__
  |     raise me from None
  | ExceptionGroup: unhandled errors in a TaskGroup (3 sub-exceptions)
  +-+---------------- 1 ----------------
    | Traceback (most recent call last):
    |   File "H:\projects\taskgroups-blog-post\taskgroups.py", line 25, in run
    |     post = await db_ses.scalar_one(q)
    |                  ^^^^^^^^^^^^^^^^^
    | AttributeError: 'AsyncSession' object has no attribute 'scalar_one'
    +---------------- 2 ----------------
    | Traceback (most recent call last):
    |   File "H:\projects\taskgroups-blog-post\taskgroups.py", line 25, in run
    |     post = await db_ses.scalar_one(q)
    |                  ^^^^^^^^^^^^^^^^^
    | AttributeError: 'AsyncSession' object has no attribute 'scalar_one'
    +---------------- 3 ----------------
    | Traceback (most recent call last):
    |   File "H:\projects\taskgroups-blog-post\taskgroups.py", line 25, in run
    |     post = await db_ses.scalar_one(q)
    |                  ^^^^^^^^^^^^^^^^^
    | AttributeError: 'AsyncSession' object has no attribute 'scalar_one'
    +------------------------------------
```

Woah! That's exactly what I was looking for, and it's formatted extremely clearly. I know
that people have been saying that the error messages are improved in newer versions of
Python, and they absolutely have been!

With traceback, I headed straight to the [`sqlalchemy` docs](https://docs.sqlalchemy.org/en/20/orm/extensions/asyncio.html)
to try and figure out what I had been misunderstanding. Digging a little bit deeper, I
found that while an `AsyncResult` object does have a
[`scalar_one()`](https://docs.sqlalchemy.org/en/20/orm/extensions/asyncio.html#sqlalchemy.ext.asyncio.AsyncResult.scalar_one)
function, I was using the ORM and getting an `AsyncSession` function back from my query.
In referencing [the docs](https://docs.sqlalchemy.org/en/20/orm/extensions/asyncio.html#sqlalchemy.ext.asyncio.AsyncSession)
for `AsyncSession`, I finally figured out that while there are `scalar()` and `scalars()`
functions, there is no `scalar_one()` function.

I then updated my `Worker.run()` function with a single change:
```diff
--- a/taskgroups.py
+++ b/taskgroups.py
@@ -22,7 +22,7 @@ class Worker:
                 post_id = await self.queue.get()
                 q = select(Post).where(Post.id == post_id)

-                post = await db_ses.scalar_one(q)
+                post = await db_ses.scalar(q)
                 await asyncio.sleep(1)  # Simulate API call
                 post.content = "Some content!"
                 await db_ses.commit()
```

And my code now ran successfully!

# Postscript

To write this post, I implemented a minimum reproducible subset of my application. On my
first attempt at implementing the `asyncio.gather()` approach, instead of a deadlock, I
got the error information that I wanted dumped right to the console:

```
Traceback (most recent call last):
  File "H:\projects\taskgroups-blog-post\asyncio_gather.py", line 56, in <module>
    asyncio.run(main())
  File "C:\Program Files\WindowsApps\PythonSoftwareFoundation.Python.3.12_3.12.496.0_x64__qbz5n2kfra8p0\Lib\asyncio\runners.py", line 194, in run
    return runner.run(main)
           ^^^^^^^^^^^^^^^^
  File "C:\Program Files\WindowsApps\PythonSoftwareFoundation.Python.3.12_3.12.496.0_x64__qbz5n2kfra8p0\Lib\asyncio\runners.py", line 118, in run
    return self._loop.run_until_complete(task)
           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "C:\Program Files\WindowsApps\PythonSoftwareFoundation.Python.3.12_3.12.496.0_x64__qbz5n2kfra8p0\Lib\asyncio\base_events.py", line 684, in run_until_complete
    return future.result()
           ^^^^^^^^^^^^^^^
  File "H:\projects\taskgroups-blog-post\asyncio_gather.py", line 51, in main
    await asyncio.gather(*tasks)
  File "H:\projects\taskgroups-blog-post\asyncio_gather.py", line 25, in run
    post = await db_ses.scalar_one(q)
                 ^^^^^^^^^^^^^^^^^
AttributeError: 'AsyncSession' object has no attribute 'scalar_one'
```

This confused me greatly! If this had happened when I was doing my initial implementation,
I would have found my problem just as fast as I would have using `TaskGroup`s. What on
earth was the difference?

Digging a bit further, I finally found the difference. In my minimum reproducible example,
I forgot to add the `return_exceptions=True` flag to my call to `asyncio.gather()`, and so
the function was called with the default value of `False`. I took another look at the
[docs](https://docs.python.org/3.12/library/asyncio-task.html#asyncio.gather):

> If return_exceptions is False (default), the first raised exception is immediately propagated to the task that awaits on gather(). Other awaitables in the aws sequence won’t be cancelled and will continue to run.
>
> If return_exceptions is True, exceptions are treated the same as successful results, and aggregated in the result list.

And now, with fresh eyes, I understand what's going on a lot better! I had set
`return_exceptions=True` because I had implemented some error handling code with using
`try/except` blocks to handle HTTP error statuses. I assumed that there was some
fundamental difference between exception handling in Python async, and that without
`return_exceptions=True`, my error handling wouldn't work. But that's not actually what it
means! It just means that `gather()` will return either the _result_ of your coroutine
_or_ the exception that was raised! Since I wasn't capturing the return value of my tasks,
I never thought to check whether there were errors being returned, and either handle or
log them.

What was happening under the hood was that my call to `asyncio.gather()` had appropriately
returned a list full of `AttributeError` exceptions... which went nowhere because I didn't
capture the return value of `gather()`. The code then moved on to awaiting the `ALL_DONE`
event... which was never going to be reached because all of the `Worker`s had exited with
exceptions.

While it's annoying to be learning this _now_, the very act of writing up this post led me
to learn even more about async in Python, so I'll take it!
