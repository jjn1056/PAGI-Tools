# PAGI-Tools dependencies. On the rebuild branch each one returns with the
# code that needs it.
# Install with: cpanm --installdeps .

requires 'perl', '5.024';  # see "Perl version support" in PAGI

# PAGI::App: the constructor, accessors with defaults, BUILD
requires 'Class::Tiny', '1.008';

on 'test' => sub {
    requires 'Test2::V0', '0.000159';
    # Fixtures that must be real module files live in t/lib
    requires 'Test::Lib', '0.003';
};
