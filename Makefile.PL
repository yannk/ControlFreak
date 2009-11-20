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
requires 'AnyEvent';
requires 'JSON::XS';

build_requires 'Test::More';

install_script 'cfkd';
install_script 'cfkctl';
install_script 'cfk-share-mem-proxy.pl';

use_test_base;
auto_include_deps;
author_tests('xt');
auto_set_repository;
WriteAll;
