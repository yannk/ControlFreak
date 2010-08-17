use inc::Module::Install;
name 'ControlFreak';
all_from 'lib/ControlFreak.pm';

include 'Module:AutoInstall';

requires 'Find::Lib';
requires 'Pod::Usage';
requires 'Try::Tiny';
requires 'Object::Tiny';
requires 'Params::Util';
requires 'Log::Log4perl';
requires 'EV';
requires 'AnyEvent' => '5.202';
requires 'JSON::XS';

build_requires 'Test::More';
build_requires 'Test::Exception';
build_requires 'Test::Deep';

install_script 'bin/cfkd';
install_script 'bin/cfkctl';
install_script 'bin/cfk-share-mem-proxy.pl';

recommends 'DateTime';
recommends 'Term::ANSIColor';

auto_include_deps;
author_tests('xt');
auto_set_repository;
WriteAll;
