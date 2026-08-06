# Large Application Diagnostic Example Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a runnable, server-rendered modular application example whose Root, Person, and Blogs packages are opaque PAGI components, and document the concrete composition gaps exposed by using only today's PAGI::Tools APIs.

**Architecture:** `MyApp::Root->to_app` is the only entry point and the only Compose boundary. Root initializes a read-only fixture repository through lifespan state, mounts Person by class name, and owns static files plus a final explicit catchall; Person and Blogs each compile their own declarative router. Local named links use Context `path_for`, a small application-owned URL module supplies cross-component links, and one application-owned View helper renders the shared HTML document shell.

**Tech Stack:** Perl 5.18-compatible source, PAGI::Compose, PAGI::Routing, PAGI::App::File, PAGI::Context::HTTP response helpers, PAGI::Test::Client, Future/Future::AsyncAwait as existing transitive runtime facilities, Test2::V0, POD/Markdown documentation, and Dist::Zilla; no new dependency.

## Global Constraints

- Implement the approved contract in `docs/superpowers/specs/2026-08-06-large-application-example-design.md`. A conflict with that design is a deviation, not permission to guess.
- Keep source compatible with Perl 5.18: no signatures, no post-5.18 syntax, no Moo/Moose, and no new CPAN dependency.
- Use only shipped PAGI::Tools behavior. Do not modify any file under `lib/PAGI/`, and do not implement cross-component reverse routing, no-match bubbling, named opaque mounts, or server loader changes.
- Root is the only Compose boundary. Person and Blogs expose class-level `to_app` methods returning independently compiled router applications.
- Mount Person and Blogs as class-name application targets. Do not replace either opaque mount with an inline subtree whose `routes` option exposes child declarations to the parent.
- Initialize `MyApp::Data` through Root's Compose lifespan and share it only through `$c->state->{data}`; do not introduce package-global mutable state or constructor threading.
- Use same-router `$c->path_for` for Person-list-to-Person-detail and Blogs-list-to-Blog-detail links. Use `MyApp::URL` only when a link crosses an opaque component boundary.
- Keep emitted 404 responses final. The example records today's child generated 404 for a routing NONE but does not simulate bubbling by buffering, response inspection, middleware, or status-code reinterpretation.
- Use the callback form of `PAGI::Test::Client->run` for integration and lifespan verification. Do not add a custom protocol harness or start a live server in tests.
- Keep HTML fixture-driven and do not echo wildcard input. Use only `MyApp::View->document($title, $body)` for the shared document shell; add no template engine or application base class.
- Use test-driven development for executable behavior: add a focused red assertion, confirm the expected failure, add the smallest implementation, then run the focused test green.
- Stage only files named by the current task. Never use `git add -A`, and never stage `.cpan-testers-fix-report.md`, `.csrf-helper-brief.md`, or `.csrf-helper-report.md`; they are unrelated user files.
- After every task commit, complete the execution workflow's review gate and update the task ledger with actual commit SHAs, exact commands, real test counts, and review evidence. Never record estimated counts.

## File Map

| File | Responsibility |
|---|---|
| `examples/15-large-application/app.pl` | Minimal loader ending in `MyApp::Root->to_app` |
| `examples/15-large-application/lib/MyApp/Data.pm` | Read-only people/blog fixture repository |
| `examples/15-large-application/lib/MyApp/URL.pm` | Cross-component path workaround with ID validation |
| `examples/15-large-application/lib/MyApp/View.pm` | Shared application-local HTML document shell |
| `examples/15-large-application/lib/MyApp/Person/Blogs.pm` | Opaque Blogs router component and local HTML outcomes |
| `examples/15-large-application/lib/MyApp/Person.pm` | Opaque Person router component and Blogs mount |
| `examples/15-large-application/lib/MyApp/Root.pm` | Compose root, lifespan, home, mounts, and root catchall |
| `examples/15-large-application/static/app.css` | Shared stylesheet served by PAGI::App::File |
| `examples/15-large-application/README.md` | Runnable example guide and package walkthrough |
| `examples/15-large-application/GAPS.md` | Evidence-backed current API gap ledger |
| `examples/README.md` | Top-level example catalog entry |
| `t/integration-large-application.t` | Unit-facing support checks plus PAGI::Test::Client component/integration coverage |

## Execution Tracking and Deviation Control

Before Task 1, create the plan-scoped workspace with the `sdd-workspace` script bundled with `superpowers:subagent-driven-development`:

```bash
/Users/jnapiorkowski/.codex/plugins/cache/openai-curated-remote/superpowers/6.2.0/skills/subagent-driven-development/scripts/sdd-workspace docs/superpowers/plans/2026-08-06-large-application-example.md
```

The command must print a directory ending in `.superpowers/sdd/2026-08-06-large-application-example`. Create its `progress.md` with this exact first line and tables:

```markdown
# SDD ledger — plan: docs/superpowers/plans/2026-08-06-large-application-example.md

| Task | Status | Commit range | Focused verification | Full-suite verification | Review |
|---|---|---|---|---|---|
| 1 | pending | — | — | — | — |
| 2 | pending | — | — | — | — |
| 3 | pending | — | — | — | — |
| 4 | pending | — | — | — | — |
| 5 | pending | — | — | — | — |

## Deviations

| ID | Status | Conflicting plan text | Evidence and rationale | Affected tasks | User decision |
|---|---|---|---|---|---|
```

The coordinator owns the ledger. A contract conflict gets the next ID
(`D-001`, `D-002`, and so on), status `awaiting decision`, the exact
conflicting plan text, concrete evidence, affected tasks, and no inferred
approval. Stop dependent work until the user decides, then record that decision
before continuing. An ordinary defect that preserves the approved contract is
fixed within its owning task and is not a deviation.

Use this Perl environment for test, POD, and packaging commands:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t/'
```

Before Task 1, record the exact baseline SHA and working-tree status:

```bash
git rev-parse HEAD
git status --short
```

Then run the full baseline suite:

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t/'
```

Record the SHA, actual file/test counts, elapsed time, existing skips, and the
three preserved untracked report files under an `## Execution Notes` heading
in `progress.md`. Do not begin Task 1 from a failing baseline without
diagnosing whether the failure is pre-existing.

---

### Task 1: Add the Data, URL, and View Support Modules

**Files:**
- Create: `examples/15-large-application/lib/MyApp/Data.pm`
- Create: `examples/15-large-application/lib/MyApp/URL.pm`
- Create: `examples/15-large-application/lib/MyApp/View.pm`
- Create: `t/integration-large-application.t`

**Interfaces:**
- Produces `MyApp::Data->new`.
- Produces `people() -> arrayref`, `person($person_id) -> hashref|undef`, `blogs_for($person_id) -> arrayref|undef`, and `blog($person_id, $blog_id) -> hashref|undef`.
- Produces class methods `MyApp::URL->people`, `->person($person_id)`, `->blogs($person_id)`, and `->blog($person_id, $blog_id)`.
- Produces `MyApp::View->document($title, $body) -> HTML string`, the only shared document-shell renderer.
- All returned fixture structures are defensive copies; URL identifiers accept only defined non-reference decimal strings.

- [ ] **Step 1: Write failing support-module tests**

Create `t/integration-large-application.t`:

```perl
use strict;
use warnings;
use Test2::V0;
use FindBin qw($Bin);
use lib "$Bin/../examples/15-large-application/lib";

use MyApp::Data;
use MyApp::URL;
use MyApp::View;

subtest 'fixture repository exposes defensive people and blog records' => sub {
    my $data = MyApp::Data->new;

    is(
        $data->people,
        [
            {
                id      => '1',
                name    => 'Ada Lovelace',
                summary => 'Mathematician and writer',
            },
            {
                id      => '2',
                name    => 'Grace Hopper',
                summary => 'Computer scientist and naval officer',
            },
            {
                id      => '3',
                name    => 'Margaret Hamilton',
                summary => 'Software engineer',
            },
        ],
        'people are returned in fixture order',
    );

    my $person = $data->person('1');
    $person->{name} = 'Changed';
    is($data->person('1')->{name}, 'Ada Lovelace',
        'person returns a defensive copy');
    is($data->person('999'), undef, 'missing person returns undef');

    my $blogs = $data->blogs_for('1');
    is([map { $_->{id} } @$blogs], ['101', '102'],
        'person blogs retain fixture order');
    $blogs->[0]{title} = 'Changed';
    is(
        $data->blog('1', '101')->{title},
        'Notes on the Analytical Engine',
        'blog records are defensive copies',
    );
    is($data->blogs_for('3'), [], 'known person may have no blogs');
    is($data->blogs_for('999'), undef,
        'missing person has no blog collection');
    is($data->blog('1', '999'), undef, 'missing blog returns undef');
};

subtest 'application URL helpers own cross-component paths' => sub {
    is(MyApp::URL->people, '/person', 'people collection path');
    is(MyApp::URL->person('2'), '/person/2', 'person detail path');
    is(MyApp::URL->blogs('2'), '/person/2/blog', 'blog collection path');
    is(
        MyApp::URL->blog('2', '201'),
        '/person/2/blog/201',
        'blog detail path',
    );

    like(
        dies { MyApp::URL->person(undef) },
        qr/person_id must be a decimal identifier/,
        'undefined person identifier is rejected',
    );
    like(
        dies { MyApp::URL->blogs('not-a-number') },
        qr/person_id must be a decimal identifier/,
        'nonnumeric person identifier is rejected',
    );
    like(
        dies { MyApp::URL->blog('1', []) },
        qr/blog_id must be a decimal identifier/,
        'reference blog identifier is rejected',
    );
};

subtest 'application View owns the shared HTML document shell' => sub {
    my $html = MyApp::View->document('Fixture title', '    <h1>Body</h1>');
    like($html, qr{<!doctype html>}, 'document declares HTML');
    like($html, qr{<title>Fixture title</title>}, 'document uses its title');
    like($html, qr{href="/static/app.css"}, 'document links shared CSS');
    like($html, qr{    <h1>Body</h1>}, 'document includes owned body markup');
};

done_testing;
```

- [ ] **Step 2: Run the focused test and confirm the modules are missing**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-large-application.t'
```

Expected: FAIL during compilation because the three support modules do not
exist.

- [ ] **Step 3: Implement the read-only fixture repository**

Create `examples/15-large-application/lib/MyApp/Data.pm`:

```perl
package MyApp::Data;

use strict;
use warnings;

my $PEOPLE = [
    {
        id      => '1',
        name    => 'Ada Lovelace',
        summary => 'Mathematician and writer',
    },
    {
        id      => '2',
        name    => 'Grace Hopper',
        summary => 'Computer scientist and naval officer',
    },
    {
        id      => '3',
        name    => 'Margaret Hamilton',
        summary => 'Software engineer',
    },
];

my $BLOGS = {
    '1' => [
        {
            id        => '101',
            person_id => '1',
            title     => 'Notes on the Analytical Engine',
            body      => 'A machine may compose elaborate and scientific pieces of music.',
        },
        {
            id        => '102',
            person_id => '1',
            title     => 'Poetical Science',
            body      => 'Imagination helps us discover what computation can express.',
        },
    ],
    '2' => [
        {
            id        => '201',
            person_id => '2',
            title     => 'Compilers and Clear Languages',
            body      => 'Programming languages should help people state ideas clearly.',
        },
    ],
    '3' => [],
};

sub new {
    my ($class) = @_;

    my %people = map { $_->{id} => +{%$_} } @$PEOPLE;
    my %blogs = map {
        my $person_id = $_;
        $person_id => [map { +{%$_} } @{$BLOGS->{$person_id}}];
    } keys %$BLOGS;

    return bless {
        people      => \%people,
        people_order => [map { $_->{id} } @$PEOPLE],
        blogs       => \%blogs,
    }, $class;
}

sub people {
    my ($self) = @_;
    return [
        map { +{%{$self->{people}{$_}}} }
        @{$self->{people_order}}
    ];
}

sub person {
    my ($self, $person_id) = @_;
    my $person = $self->{people}{$person_id};
    return defined $person ? +{%$person} : undef;
}

sub blogs_for {
    my ($self, $person_id) = @_;
    return undef unless exists $self->{people}{$person_id};
    my $blogs = $self->{blogs}{$person_id} || [];
    return [map { +{%$_} } @$blogs];
}

sub blog {
    my ($self, $person_id, $blog_id) = @_;
    return undef unless exists $self->{people}{$person_id};
    my ($blog) = grep {
        $_->{id} eq $blog_id
    } @{$self->{blogs}{$person_id} || []};
    return defined $blog ? +{%$blog} : undef;
}

1;
```

- [ ] **Step 4: Implement validated cross-component paths**

Create `examples/15-large-application/lib/MyApp/URL.pm`:

```perl
package MyApp::URL;

use strict;
use warnings;
use Carp qw(croak);

sub _id {
    my ($label, $value) = @_;
    croak "$label must be a decimal identifier"
        unless defined $value
            && !ref($value)
            && $value =~ /\A\d+\z/;
    return "$value";
}

sub people {
    return '/person';
}

sub person {
    my ($class, $person_id) = @_;
    $person_id = _id('person_id', $person_id);
    return "/person/$person_id";
}

sub blogs {
    my ($class, $person_id) = @_;
    $person_id = _id('person_id', $person_id);
    return "/person/$person_id/blog";
}

sub blog {
    my ($class, $person_id, $blog_id) = @_;
    $person_id = _id('person_id', $person_id);
    $blog_id = _id('blog_id', $blog_id);
    return "/person/$person_id/blog/$blog_id";
}

1;
```

- [ ] **Step 5: Implement the shared document shell**

Create `examples/15-large-application/lib/MyApp/View.pm`:

```perl
package MyApp::View;

use strict;
use warnings;

sub document {
    my ($class, $title, $body) = @_;
    return <<"HTML";
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$title</title>
  <link rel="stylesheet" href="/static/app.css">
</head>
<body>
  <main class="page">
$body
  </main>
</body>
</html>
HTML
}

1;
```

- [ ] **Step 6: Run the support tests green**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-large-application.t'
```

Expected: PASS.

- [ ] **Step 7: Inspect and commit Task 1**

```bash
git diff --check
git diff -- examples/15-large-application/lib/MyApp/Data.pm examples/15-large-application/lib/MyApp/URL.pm examples/15-large-application/lib/MyApp/View.pm t/integration-large-application.t
git add examples/15-large-application/lib/MyApp/Data.pm examples/15-large-application/lib/MyApp/URL.pm examples/15-large-application/lib/MyApp/View.pm t/integration-large-application.t
git commit -m "examples: add modular application support modules"
```

Update Task 1's ledger row with the commit SHA, focused command/count, and
review result.

---

### Task 2: Add the Independently Compiled Blogs Component

**Files:**
- Create: `examples/15-large-application/lib/MyApp/Person/Blogs.pm`
- Modify: `t/integration-large-application.t`

**Interfaces:**
- Produces class method `MyApp::Person::Blogs->to_app -> CODE`.
- Consumes inherited `path_params->{person_id}` and shared `state->{data}`.
- Names local routes `index` and `show`; list-to-detail links use
  `$c->path_for('show', { blog_id => $id })`.
- Uses `MyApp::URL` only for links back across the opaque mount boundary.
- A missing numeric blog ID is a handler-owned HTML 404; `/*path` is an
  explicit Blogs-owned catchall; POST to a GET route remains a child 405.

- [ ] **Step 1: Add a data-backed mounted-component test**

Add these imports after the existing `use MyApp::URL;` line in
`t/integration-large-application.t`:

```perl
use PAGI::Compose qw(compose);
use PAGI::Routing qw(mount);
use PAGI::Test::Client;
```

Add this helper before the first subtest:

```perl
sub _app_with_data {
    my ($routes) = @_;
    return compose(
        routes => $routes,
        lifespan => {
            startup => sub {
                my ($state, $scope) = @_;
                $state->{data} = MyApp::Data->new;
                return;
            },
            shutdown => sub {
                my ($state, $scope) = @_;
                delete $state->{data};
                return;
            },
        },
    )->to_app;
}
```

Add this subtest before `done_testing`:

```perl
subtest 'Blogs owns local links, handler 404, catchall, and 405' => sub {
    my $app = _app_with_data([
        mount('/person/{person_id}/blog' => 'MyApp::Person::Blogs',
            constraints => { person_id => qr/\d+/ },
        ),
    ]);

    PAGI::Test::Client->run($app, sub {
        my ($client) = @_;

        my $list = $client->get('/person/1/blog');
        is($list->status, 200, 'blog collection responds');
        like($list->text, qr{<h1>Blogs by Ada Lovelace</h1>},
            'blog collection identifies the inherited person');
        like($list->text, qr{href="/person/1/blog/101"},
            'local path_for generates the mounted blog detail path');

        my $detail = $client->get('/person/1/blog/101');
        is($detail->status, 200, 'blog detail responds');
        like($detail->text, qr{<h1>Notes on the Analytical Engine</h1>},
            'blog detail renders fixture content');
        like($detail->text, qr{href="/person/1"},
            'cross-component person link uses the application URL contract');

        my $missing = $client->get('/person/1/blog/999');
        is($missing->status, 404, 'unknown numeric blog is a handler 404');
        like($missing->text, qr{<h1>Blog not found</h1>},
            'unknown numeric blog uses the Blogs handler response');

        my $caught = $client->get('/person/1/blog/not/a/route');
        is($caught->status, 404, 'deeper unknown blog path is caught');
        like($caught->text, qr{<h1>Blogs section not found</h1>},
            'explicit Blogs catchall owns the deeper path');

        my $wrong_method = $client->post('/person/1/blog/101');
        is($wrong_method->status, 405, 'Blogs owns wrong-method outcome');
        is($wrong_method->header('Allow'), 'GET, HEAD',
            'Blogs 405 retains normalized Allow');
    });
};
```

- [ ] **Step 2: Run the focused test and confirm class loading fails**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-large-application.t'
```

Expected: FAIL because `MyApp::Person::Blogs` cannot be loaded.

- [ ] **Step 3: Create the Blogs router and page renderer**

Create `examples/15-large-application/lib/MyApp/Person/Blogs.pm`:

```perl
package MyApp::Person::Blogs;

use strict;
use warnings;
use PAGI::Routing qw(router route);
use MyApp::URL ();
use MyApp::View ();

sub list_blogs {
    my ($c) = @_;
    my $person_id = $c->path_param('person_id');
    my $data = $c->state->{data};
    my $person = $data->person($person_id);

    unless ($person) {
        return $c->html(
            MyApp::View->document(
                'Blogs not found',
                '    <h1>Blogs not found</h1>'
                    . "\n    <p>The requested person does not exist.</p>",
            ),
            status => 404,
        );
    }

    my $blogs = $data->blogs_for($person_id);
    my @items;
    for my $blog (@$blogs) {
        my $path = $c->path_for('show', { blog_id => $blog->{id} });
        push @items,
            qq{      <li><a href="$path">$blog->{title}</a></li>};
    }
    my $items = @items
        ? join("\n", @items)
        : '      <li>No posts yet.</li>';
    my $person_path = MyApp::URL->person($person_id);

    return $c->html(MyApp::View->document(
        "Blogs by $person->{name}",
        <<"BODY",
    <nav><a href="/">Home</a> / <a href="$person_path">$person->{name}</a></nav>
    <h1>Blogs by $person->{name}</h1>
    <ul>
$items
    </ul>
BODY
    ));
}

sub show_blog {
    my ($c) = @_;
    my $person_id = $c->path_param('person_id');
    my $blog_id = $c->path_param('blog_id');
    my $data = $c->state->{data};
    my $blog = $data->blog($person_id, $blog_id);

    unless ($blog) {
        my $blogs_path = MyApp::URL->blogs($person_id);
        return $c->html(
            MyApp::View->document(
                'Blog not found',
                qq{    <nav><a href="$blogs_path">Blogs</a></nav>}
                    . "\n    <h1>Blog not found</h1>"
                    . "\n    <p>No blog has that identifier.</p>",
            ),
            status => 404,
        );
    }

    my $blogs_path = MyApp::URL->blogs($person_id);
    my $person_path = MyApp::URL->person($person_id);
    return $c->html(MyApp::View->document(
        $blog->{title},
        <<"BODY",
    <nav><a href="/">Home</a> / <a href="$person_path">Person</a> / <a href="$blogs_path">Blogs</a></nav>
    <article>
      <h1>$blog->{title}</h1>
      <p>$blog->{body}</p>
    </article>
BODY
    ));
}

sub blogs_not_found {
    my ($c) = @_;
    my $person_id = $c->path_param('person_id');
    my $blogs_path = MyApp::URL->blogs($person_id);
    return $c->html(
        MyApp::View->document(
            'Blogs section not found',
            qq{    <nav><a href="$blogs_path">Blogs</a></nav>}
                . "\n    <h1>Blogs section not found</h1>"
                . "\n    <p>No Blogs route matched this path.</p>",
        ),
        status => 404,
    );
}

sub to_app {
    return router(
        routes => [
            route('/' => \&list_blogs, name => 'index'),
            route('/{blog_id}' => \&show_blog,
                name        => 'show',
                constraints => { blog_id => qr/\d+/ },
            ),
            route('/*path' => \&blogs_not_found),
        ],
    )->to_app;
}

1;
```

- [ ] **Step 4: Compile the component directly**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -Iexamples/15-large-application/lib -MMyApp::Person::Blogs -e "my \$app = MyApp::Person::Blogs->to_app; die q(not code) unless ref(\$app) eq q(CODE)"'
```

Expected: exit 0 with no output.

- [ ] **Step 5: Run the mounted Blogs behavior green**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-large-application.t'
```

Expected: PASS.

- [ ] **Step 6: Inspect and commit Task 2**

```bash
git diff --check
git diff -- examples/15-large-application/lib/MyApp/Person/Blogs.pm t/integration-large-application.t
git add examples/15-large-application/lib/MyApp/Person/Blogs.pm t/integration-large-application.t
git commit -m "examples: add modular Blogs component"
```

Update Task 2's ledger row with the commit SHA, focused command/count, and
review result.

---


### Task 3: Add the Person Component and Opaque Blogs Mount

**Files:**
- Create: `examples/15-large-application/lib/MyApp/Person.pm`
- Modify: `t/integration-large-application.t`

**Interfaces:**
- Produces class method `MyApp::Person->to_app -> CODE`.
- Names local routes `index` and `show`; list-to-detail links use
  `$c->path_for('show', { person_id => $id })`.
- Mounts `MyApp::Person::Blogs` opaquely at `/{person_id}/blog`.
- Uses `MyApp::URL->blogs($person_id)` for the cross-component link.
- A missing numeric person is a Person handler-owned 404. Person declares no
  catchall, preserving the GAP-02 diagnostic case.

- [ ] **Step 1: Add failing mounted Person tests**

Add this subtest before `done_testing` in
`t/integration-large-application.t`:

```perl
subtest 'Person owns local routes and mounts Blogs as an application' => sub {
    my $app = _app_with_data([
        mount('/person' => 'MyApp::Person'),
    ]);

    PAGI::Test::Client->run($app, sub {
        my ($client) = @_;

        my $list = $client->get('/person');
        is($list->status, 200, 'person collection responds');
        like($list->text, qr{<h1>People</h1>},
            'person collection renders its page');
        like($list->text, qr{href="/person/1"},
            'local path_for generates the mounted person detail path');

        my $detail = $client->get('/person/1');
        is($detail->status, 200, 'person detail responds');
        like($detail->text, qr{<h1>Ada Lovelace</h1>},
            'person detail renders fixture content');
        like($detail->text, qr{href="/person/1/blog"},
            'cross-component Blogs link uses the application URL contract');

        my $missing = $client->get('/person/999');
        is($missing->status, 404, 'unknown numeric person is a handler 404');
        like($missing->text, qr{<h1>Person not found</h1>},
            'unknown numeric person uses the Person handler response');

        my $blogs = $client->get('/person/1/blog');
        is($blogs->status, 200, 'opaque Blogs child is reachable');
        like($blogs->text, qr{<h1>Blogs by Ada Lovelace</h1>},
            'Blogs receives the inherited person path parameter');
    });
};
```

- [ ] **Step 2: Run the focused test and confirm Person cannot be loaded**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-large-application.t'
```

Expected: FAIL because `MyApp::Person` cannot be loaded. The Task 1 and Task 2
subtests remain green.

- [ ] **Step 3: Create Person's page handlers**

Create `examples/15-large-application/lib/MyApp/Person.pm`:

```perl
package MyApp::Person;

use strict;
use warnings;
use PAGI::Routing qw(router route mount);
use MyApp::URL ();
use MyApp::View ();

sub list_people {
    my ($c) = @_;
    my $people = $c->state->{data}->people;
    my @items;

    for my $person (@$people) {
        my $path = $c->path_for('show', { person_id => $person->{id} });
        push @items,
            qq{      <li><a href="$path">$person->{name}</a> — $person->{summary}</li>};
    }

    my $items = join("\n", @items);
    return $c->html(MyApp::View->document(
        'People',
        <<"BODY",
    <nav><a href="/">Home</a></nav>
    <h1>People</h1>
    <ul>
$items
    </ul>
BODY
    ));
}

sub show_person {
    my ($c) = @_;
    my $person_id = $c->path_param('person_id');
    my $person = $c->state->{data}->person($person_id);

    unless ($person) {
        my $people_path = MyApp::URL->people;
        return $c->html(
            MyApp::View->document(
                'Person not found',
                qq{    <nav><a href="$people_path">People</a></nav>}
                    . "\n    <h1>Person not found</h1>"
                    . "\n    <p>No person has that identifier.</p>",
            ),
            status => 404,
        );
    }

    my $people_path = MyApp::URL->people;
    my $blogs_path = MyApp::URL->blogs($person_id);
    return $c->html(MyApp::View->document(
        $person->{name},
        <<"BODY",
    <nav><a href="/">Home</a> / <a href="$people_path">People</a></nav>
    <h1>$person->{name}</h1>
    <p>$person->{summary}</p>
    <p><a href="$blogs_path">Read this person's blogs</a></p>
BODY
    ));
}

sub to_app {
    return router(
        routes => [
            route('/' => \&list_people, name => 'index'),
            route('/{person_id}' => \&show_person,
                name        => 'show',
                constraints => { person_id => qr/\d+/ },
            ),
            mount('/{person_id}/blog' => 'MyApp::Person::Blogs',
                constraints => { person_id => qr/\d+/ },
            ),
        ],
    )->to_app;
}

1;
```

- [ ] **Step 4: Compile Person and its opaque child**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -Iexamples/15-large-application/lib -MMyApp::Person -e "my \$app = MyApp::Person->to_app; die q(not code) unless ref(\$app) eq q(CODE)"'
```

Expected: exit 0 with no output. Compilation must auto-load
`MyApp::Person::Blogs` through the class-name mount target.

- [ ] **Step 5: Run the Person and nested Blogs behavior green**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-large-application.t'
```

Expected: PASS.

- [ ] **Step 6: Inspect and commit Task 3**

```bash
git diff --check
git diff -- examples/15-large-application/lib/MyApp/Person.pm t/integration-large-application.t
git add examples/15-large-application/lib/MyApp/Person.pm t/integration-large-application.t
git commit -m "examples: add modular Person component"
```

Update Task 3's ledger row with the commit SHA, focused command/count, and
review result.

---

### Task 4: Compose Root, Lifespan, Static Files, and the Full Application

**Files:**
- Create: `examples/15-large-application/lib/MyApp/Root.pm`
- Create: `examples/15-large-application/app.pl`
- Create: `examples/15-large-application/static/app.css`
- Modify: `t/integration-large-application.t`

**Interfaces:**
- Produces `MyApp::Root->to_app -> CODE`, the application entry point.
- Root startup installs `MyApp::Data->new` at `state->{data}`; shutdown
  removes the same key.
- Root mounts `PAGI::App::File` at `/static`, mounts `MyApp::Person`
  opaquely at `/person`, and declares a final ordinary `/*path` catchall.
- `app.pl` adjusts only `@INC`, loads Root, and evaluates
  `MyApp::Root->to_app`.
- The integration matrix uses only `PAGI::Test::Client->run`.

- [ ] **Step 1: Add the failing Root and full-application integration matrix**

Add this import after `use MyApp::URL;` in
`t/integration-large-application.t`:

```perl
use MyApp::Root ();
```

Add this subtest before `done_testing`:

```perl
subtest 'Root composes lifespan, components, navigation, and outcomes' => sub {
    my $direct_app = MyApp::Root->to_app;
    is(ref($direct_app), 'CODE', 'Root class compiles to a PAGI app');

    my $app_file = "$Bin/../examples/15-large-application/app.pl";
    my $app = do $app_file;
    my $load_error = $@ || $!;
    ok(!$load_error, 'minimal app.pl loads cleanly') or diag($load_error);
    is(ref($app), 'CODE', 'app.pl returns Root compiled as a PAGI app');

    my $state;
    PAGI::Test::Client->run($app, sub {
        my ($client) = @_;
        $state = $client->state;
        isa_ok($state->{data}, 'MyApp::Data');

        my $home = $client->get('/');
        is($home->status, 200, 'Root home responds');
        like($home->text, qr{<h1>My PAGI People</h1>},
            'Root home renders its page');
        like($home->text, qr{href="/person"},
            'Root-to-Person link uses MyApp::URL');

        my $people = $client->get('/person');
        is($people->status, 200, 'Person collection is mounted');
        like($people->text, qr{href="/person/1"},
            'Person local named route produces a working link');

        my $person = $client->get('/person/1');
        is($person->status, 200, 'Person detail is reachable');
        like($person->text, qr{href="/person/1/blog"},
            'Person-to-Blogs cross-component link works');

        my $blogs = $client->get('/person/1/blog');
        is($blogs->status, 200, 'Blogs collection is mounted');
        like($blogs->text, qr{href="/person/1/blog/101"},
            'Blogs local named route produces a working link');

        my $blog = $client->get('/person/1/blog/101');
        is($blog->status, 200, 'Blog detail is reachable');
        like($blog->text, qr{href="/person/1"},
            'Blogs-to-Person cross-component link works');

        my $person_missing = $client->get('/person/999');
        is($person_missing->status, 404,
            'matched missing person is a local handler 404');
        like($person_missing->text, qr{<h1>Person not found</h1>},
            'Person handler 404 remains untouched');

        my $blog_missing = $client->get('/person/1/blog/999');
        is($blog_missing->status, 404,
            'matched missing blog is a local handler 404');
        like($blog_missing->text, qr{<h1>Blog not found</h1>},
            'Blogs handler 404 remains untouched');

        my $blogs_catchall = $client->get('/person/1/blog/not/a/route');
        is($blogs_catchall->status, 404,
            'Blogs explicit catchall owns deeper paths');
        like($blogs_catchall->text,
            qr{<h1>Blogs section not found</h1>},
            'Blogs catchall body remains local');

        my $root_missing = $client->get('/outside');
        is($root_missing->status, 404, 'Root catchall handles root miss');
        like($root_missing->text, qr{<h1>Root page not found</h1>},
            'Root catchall is an ordinary branded route');

        my $child_none = $client->get('/person/1/unmatched');
        is($child_none->status, 404,
            'current opaque Person mount owns its routing NONE');
        is($child_none->text, 'Not Found',
            'GAP-02 evidence: generated child 404 cannot bubble to Root');

        my $wrong_method = $client->post('/person/1/blog/101');
        is($wrong_method->status, 405, 'child PARTIAL remains final');
        is($wrong_method->header('Allow'), 'GET, HEAD',
            'child 405 carries the normalized Allow header');

        my $css = $client->get('/static/app.css');
        is($css->status, 200, 'static stylesheet is mounted');
        is($css->header('Content-Type'), 'text/css',
            'file app selects the CSS media type');
        like($css->text, qr/\.page\s*\{/,
            'mounted stylesheet contains its recognizable page rule');

        my $static_missing = $client->get('/static/missing.css');
        is($static_missing->status, 404,
            'missing static asset remains owned by the file app');
        unlike($static_missing->text, qr{<h1>Root page not found</h1>},
            'native application 404 is not reinterpreted as Root decline');

        my $head = $client->head('/person/1');
        is($head->status, 200, 'automatic HEAD reaches Person GET');
        is($head->content, '', 'HEAD suppresses the HTML body');
        is(
            $head->header('Content-Length'),
            $person->header('Content-Length'),
            'HEAD preserves GET-equivalent Content-Length',
        );
    });

    ok(!exists $state->{data},
        'Root shutdown removes Data from the same server state');
};
```

- [ ] **Step 2: Run the focused test and confirm Root is missing**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-large-application.t'
```

Expected: FAIL during compilation because `MyApp/Root.pm` does not exist.

- [ ] **Step 3: Implement Root's Compose boundary**

Create `examples/15-large-application/lib/MyApp/Root.pm`:

```perl
package MyApp::Root;

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;
use PAGI::App::File;
use PAGI::Compose qw(compose);
use PAGI::Routing qw(route mount);
use MyApp::Data;
use MyApp::URL ();
use MyApp::View ();

my $STATIC_ROOT = File::Spec->catdir(
    dirname(__FILE__),
    '..',
    '..',
    'static',
);

sub startup {
    my ($state, $scope) = @_;
    $state->{data} = MyApp::Data->new;
    return;
}

sub shutdown {
    my ($state, $scope) = @_;
    delete $state->{data};
    return;
}

sub home {
    my ($c) = @_;
    my $count = scalar @{$c->state->{data}->people};
    my $people_path = MyApp::URL->people;
    return $c->html(MyApp::View->document(
        'My PAGI People',
        <<"BODY",
    <h1>My PAGI People</h1>
    <p>This modular application contains $count fixture people.</p>
    <p><a href="$people_path">Browse people</a></p>
BODY
    ));
}

sub not_found {
    my ($c) = @_;
    return $c->html(
        MyApp::View->document(
            'Root page not found',
            '    <h1>Root page not found</h1>'
                . "\n    <p>No application route matched this path.</p>",
        ),
        status => 404,
    );
}

sub _static_app {
    return PAGI::App::File->new(root => $STATIC_ROOT);
}

sub to_app {
    return compose(
        routes => [
            route('/' => \&home, name => 'home'),
            mount('/static' => _static_app()),
            mount('/person' => 'MyApp::Person'),
            route('/*path' => \&not_found),
        ],
        lifespan => {
            startup  => \&startup,
            shutdown => \&shutdown,
        },
    )->to_app;
}

1;
```

- [ ] **Step 4: Add the minimal loader and stylesheet**

Create `examples/15-large-application/app.pl`:

```perl
use strict;
use warnings;
use File::Basename qw(dirname);
use lib dirname(__FILE__) . '/lib';
use MyApp::Root ();

MyApp::Root->to_app;
```

Create `examples/15-large-application/static/app.css`:

```css
:root {
  color: #20242a;
  background: #f5f2ea;
  font-family: system-ui, sans-serif;
}

body {
  margin: 0;
}

.page {
  max-width: 48rem;
  margin: 3rem auto;
  padding: 2rem;
  background: #fff;
  border: 1px solid #d8d1c4;
  border-radius: 0.75rem;
}

a {
  color: #76511a;
}

li + li {
  margin-top: 0.6rem;
}
```

- [ ] **Step 5: Compile both supported entry shapes**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -Iexamples/15-large-application/lib -MMyApp::Root -e "my \$app = MyApp::Root->to_app; die q(not code) unless ref(\$app) eq q(CODE)"'
```

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -e "my \$app = do q(examples/15-large-application/app.pl); die(\$@ || \$! || q(not code)) unless ref(\$app) eq q(CODE)"'
```

Expected: exit 0 with no output.

- [ ] **Step 6: Run the complete PAGI::Test::Client integration matrix**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-large-application.t'
```

Expected: PASS. This command must exercise startup, every HTTP assertion, and
shutdown through `PAGI::Test::Client->run`.

- [ ] **Step 7: Inspect and commit Task 4**

```bash
git diff --check
git diff -- examples/15-large-application/lib/MyApp/Root.pm examples/15-large-application/app.pl examples/15-large-application/static/app.css t/integration-large-application.t
git add examples/15-large-application/lib/MyApp/Root.pm examples/15-large-application/app.pl examples/15-large-application/static/app.css t/integration-large-application.t
git commit -m "examples: compose modular application root"
```

Update Task 4's ledger row with the commit SHA, focused command/count, and
review result.

---

### Task 5: Document the Architecture, Gaps, and Verified Example

**Files:**
- Create: `examples/15-large-application/README.md`
- Create: `examples/15-large-application/GAPS.md`
- Modify: `examples/README.md`

**Interfaces:**
- Documents the currently runnable file-loader command separately from the
  explicitly unshipped `--lib/--module/-e` target syntax.
- Records GAP-01 and GAP-02 as confirmed current limitations with evidence and
  bounded desired behavior.
- Records GAP-03 as an observation that is not promoted to a core feature
  proposal from this example alone.
- Adds no executable behavior and changes no core library file.

- [ ] **Step 1: Write the evidence-backed gaps ledger**

Create `examples/15-large-application/GAPS.md`:

```markdown
# Gaps Exposed by the Modular Application

This example intentionally uses only APIs currently shipped by PAGI::Tools.
The entries below separate desired application behavior from current behavior
and from the workaround used by the example.

## GAP-01: Reverse routing across opaque component mounts

**Desired behavior:** A parent can assign a stable name to an opaque component
placement, and application code can address named routes below that placement.
For example, a Blogs mount named `blogs` could expose `blogs.index`. The
placement name, not the package name, identifies the URL because one component
may be mounted more than once.

**Shipped behavior:** An opaque application mount has no route name and hides
the mounted router's named leaves from the parent resolver.
`PAGI::Context->path_for` and `url_for` use the innermost compatible routing
frame, so Person cannot reverse a Blogs route and Blogs cannot reverse a Person
route.

**Evidence:** Person list links to Person detail and Blogs list links to Blog
detail with local `$c->path_for`. Root-to-Person, Person-to-Blogs, and
Blogs-to-Person links cannot use those local resolvers.

**Current workaround:** `MyApp::URL` owns the cross-component paths. This
keeps literal mount paths out of handlers but duplicates the mount structure in
application code.

**Follow-on status:** Requires a separate core design. This example does not
define the metadata or lookup protocol.

## GAP-02: Cooperative no-match bubbling through component mounts

**Desired behavior:** When a routing-aware mounted component has a genuine
NONE result, it declines without sending and its parent resumes
declaration-order scanning. A child FULL match, PARTIAL method match, explicit
catchall, or emitted response remains final. Arbitrary native PAGI
applications remain terminal unless they explicitly adopt a future cooperative
contract.

**Shipped behavior:** Once an opaque application mount prefix matches, that
mount owns the request. If the mounted router has no matching route, it sends
its generated 404 before the parent can resume.

**Evidence:** `GET /person/1/unmatched` returns the Person router's plain
`Not Found` response instead of reaching Root's explicit branded catchall.
In contrast, an unknown numeric blog is handled by `show_blog`, and a deeper
Blogs path is handled by Blogs' explicit catchall; both correctly remain local.
A wrong method remains a child 405 with `Allow: GET, HEAD`.

**Current workaround:** None. The example records shipped behavior rather than
buffering events or treating an emitted 404 as control flow.

**Follow-on status:** Requires a separate routing-component decline design.

## GAP-03: Repeated component shell

Person and Blogs repeat a short set of imports plus a method that passes their
route array through `router` and then `to_app`. The repetition is visible, but two
small components do not justify a base class, role, or new core constructor.
This remains an observation rather than a proposed PAGI::Tools feature.

The application-local `MyApp::View` helper already removes unrelated HTML
document-shell duplication, so this observation is specifically about
component construction.

If larger applications reveal repeated lifecycle, middleware, configuration,
or inspection contracts in addition to this small wrapper, a higher-order
framework built on PAGI::Tools may be the right place to address them.

## Deferred server loader

The desired command shape is:

```text
pagi-server --lib /Project-MyApp/lib --module MyApp::Root \
    -e 'MyApp::Root->to_app'
```

That syntax is not currently shipped. It belongs to PAGI::Server loader work,
not to the PAGI::Tools composition gaps above. This example uses `app.pl`.
```

- [ ] **Step 2: Write the runnable example guide**

Create `examples/15-large-application/README.md`:

```markdown
# Large Modular HTML Application

This example shows one way to structure a larger PAGI::Tools application as
opaque package components. All application behavior lives under `lib/`;
`app.pl` only loads `MyApp::Root` and returns `MyApp::Root->to_app`.

## Run it

From the PAGI-Tools checkout:

```bash
perl -Ilib bin/pagi-server --app \
    examples/15-large-application/app.pl --port 5000
```

Then open <http://localhost:5000/>.

This future loader shape is intentionally not available yet:

```text
pagi-server --lib examples/15-large-application/lib \
    --module MyApp::Root -e 'MyApp::Root->to_app'
```

## Application tree

```text
lib/MyApp/
├── Data.pm
├── Root.pm
├── URL.pm
├── View.pm
├── Person.pm
└── Person/
    └── Blogs.pm
```

- `MyApp::Root` is the Compose boundary. It owns lifespan, `/`,
  `/static`, the Person mount, and the final root catchall.
- `MyApp::Person` is an independently compiled router mounted at
  `/person`.
- `MyApp::Person::Blogs` is another independently compiled router mounted by
  Person at `/{person_id}/blog`.
- `MyApp::Data` is created during startup and shared through
  `$c->state->{data}`.
- `MyApp::URL` centralizes links that cross opaque component boundaries.
- `MyApp::View` renders the shared HTML document shell without introducing a
  template engine.

## Routes

| Path | Owner |
|---|---|
| `/` | Root |
| `/person` | Person |
| `/person/{person_id}` | Person |
| `/person/{person_id}/blog` | Blogs |
| `/person/{person_id}/blog/{blog_id}` | Blogs |
| `/static/app.css` | PAGI::App::File |

Person list links to Person detail with Person's local named route. Blogs list
links to Blog detail with Blogs' local named route. Links that cross an opaque
mount use `MyApp::URL`; [GAPS.md](GAPS.md) explains why.

## Outcomes worth trying

- `/person/999` is a Person handler-owned 404.
- `/person/1/blog/999` is a Blogs handler-owned 404.
- `/person/1/blog/not/a/route` is handled by Blogs' explicit catchall.
- `/outside` is handled by Root's explicit catchall.
- `/person/1/unmatched` shows today's generated child 404 because opaque
  mount no-match bubbling is not yet available.

## Test it

```bash
prove -lv t/integration-large-application.t
```

The integration test uses `PAGI::Test::Client->run`, including lifespan
startup and shutdown. It does not start a live server.
```

- [ ] **Step 3: Add the example to the top-level catalog**

Replace the `## Example List` numbered list in `examples/README.md` with:

```markdown
1. `09-psgi-bridge` - wraps a PSGI app for PAGI use (via `PAGI::App::WrapPSGI`)
2. `10-chat-showcase` - Compose-rooted chat demo with application-wide logging and a mutable HTTP/WebSocket/SSE target router
3. `13-contact-form` - form parsing and file uploads
4. `14-lifespan-utils` - lifespan hooks via `PAGI::Utils`
5. `15-large-application` - Compose-rooted modular HTML application with opaque Person/Blogs components, lifespan data, working links, and an evidence-backed gaps ledger
6. `app-01-file` - static file serving with `PAGI::App::File`
7. `background-tasks` - running background work from within a PAGI app
8. `compose` - optional application root combining declarative routes, request-ID middleware, server-owned lifecycle state, automatic HEAD, and verified shutdown
9. `declarative-routing` - immutable `PAGI::Routing` tree with package handlers, an inline mount, route middleware, custom fallbacks, and reverse URLs
10. `endpoint-demo` - high-level HTTP endpoint with `PAGI::Endpoint::HTTP`
11. `endpoint-router-demo` - composing routes with `PAGI::Endpoint::Router`
12. `full-demo` - kitchen-sink demo combining multiple toolkit features
13. `sse-dashboard` - server-sent events dashboard with `PAGI::Endpoint::SSE`
14. `test-lifespan-shutdown` - testing graceful lifespan shutdown hooks
15. `websocket-chat-v2` - WebSocket chat using `PAGI::Endpoint::WebSocket`
16. `websocket-echo-v2` - WebSocket echo using `PAGI::Endpoint::WebSocket`
17. `websocket-bidirectional` - full-duplex WebSocket with `PAGI::Context`: a receive-loop (`each_text`) and an unsolicited server send-loop running concurrently
```

Do not change the requirements or symlink note around that list.

- [ ] **Step 4: Run focused compilation and integration verification**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -Iexamples/15-large-application/lib -c examples/15-large-application/app.pl'
```

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -Iexamples/15-large-application/lib -c examples/15-large-application/lib/MyApp/Data.pm'
```

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -Iexamples/15-large-application/lib -c examples/15-large-application/lib/MyApp/URL.pm'
```

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -Iexamples/15-large-application/lib -c examples/15-large-application/lib/MyApp/View.pm'
```

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -Iexamples/15-large-application/lib -c examples/15-large-application/lib/MyApp/Person/Blogs.pm'
```

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -Iexamples/15-large-application/lib -c examples/15-large-application/lib/MyApp/Person.pm'
```

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -Iexamples/15-large-application/lib -c examples/15-large-application/lib/MyApp/Root.pm'
```

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lv t/integration-large-application.t'
```

Expected: every file reports `syntax OK` and the focused test passes.

- [ ] **Step 5: Run the full distribution verification**

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -lr t/'
```

Expected: PASS. Record actual files, tests, elapsed time, and existing skips in
the ledger.

```bash
/bin/bash -lc 'source /Users/jnapiorkowski/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && dzil test'
```

Expected: PASS. If the sandbox alone prevents the existing loopback integration
test from binding, rerun the identical command with loopback permission and
record both results; do not weaken or skip the test.

- [ ] **Step 6: Audit scope, documentation claims, and protected files**

```bash
git diff --check
git diff --name-only main -- lib/PAGI
git diff -- examples/15-large-application/README.md examples/15-large-application/GAPS.md examples/README.md
git status --short
```

Expected:

- `git diff --name-only main -- lib/PAGI` prints nothing.
- README labels the module-expression server command as future syntax.
- GAPS distinguishes handler/catchall 404s from routing NONE and keeps 405
  final.
- GAP-03 remains an observation, not a new core abstraction.
- The three unrelated report files remain untracked and unstaged.

- [ ] **Step 7: Commit the documentation and catalog**

```bash
git add examples/15-large-application/README.md examples/15-large-application/GAPS.md examples/README.md
git commit -m "docs: explain modular application example"
```

Update Task 5's ledger row with the commit SHA, focused/full/package commands
and real counts, scope audit, and review result.

---

## Final Review Gate

After Task 5:

1. Run the complete feature review required by the execution skill against the
   implementation branch's baseline.
2. Confirm the diff contains only the example, its integration test, the
   example catalog, this plan/spec, and execution-ledger artifacts permitted by
   the workflow.
3. Confirm every acceptance criterion in
   `docs/superpowers/specs/2026-08-06-large-application-example-design.md` has
   direct test or documentation evidence.
4. Run `git diff --check`, the focused integration test, `prove -lr t/`, and
   `dzil test` again at the reviewed HEAD if any review fix changes source,
   tests, or documentation.
5. Record review findings and any fix-round commit range in the ledger before
   invoking `superpowers:finishing-a-development-branch`.
