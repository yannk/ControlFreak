use strict;
use Find::Lib libs => ['../lib', '.'];
use Test::More tests => 11;
use Test::Exception;
use Test::Deep;
use ControlFreak;

require 'testutils.pl';
shutoff_logs();

{
    my $ctrl = ControlFreak->new();
    my $svc = $ctrl->find_or_create_svc('testsvc');
    is_deeply $svc->tag_list, [], "no tags by defaults";
    is_deeply $svc->tags, {}, "no tags by defaults";
    ok $svc->set_tags('t1,t2'), "tags set";
    cmp_bag $svc->tag_list, ['t1', 't2'], "tags split and set";
    is_deeply $svc->tags, { 't1' => 1, 't2' => 1 }, "tags as a hashref";
    ok $svc->set_tags('t3'), "tag set";
    is_deeply $svc->tag_list, ['t3'], "only one tag";

    my $svc2 = $ctrl->find_or_create_svc('testsvc2');
    ok $svc2->set_tags('t1,t3,t3,t3'), "set";
    cmp_bag [ $ctrl->services_from_args(args => [ 'tag', 't1' ]) ],
            [ $svc2 ], "what is called from the console";
    cmp_bag [ $ctrl->services_by_tag('t1') ], [ $svc2 ], "API call";
    cmp_bag [ $ctrl->services_by_tag('t3') ], [ $svc, $svc2 ], "API call";
}
