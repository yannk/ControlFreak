use inc::Module::Install;
name 'ControlFreak';
all_from 'lib/ControlFreak.pm';

build_requires 'Test::More';
use_test_base;
auto_include_deps;
author_tests('xt');
auto_set_repository;
WriteAll;
