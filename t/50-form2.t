#!perl -w
use strict;
use Test::More;
use Test::Deep;
use Log::Log4perl qw(:easy);

use WWW::Mechanize::Chrome;
use lib '.';

use t::helper;
use Time::HiRes qw(sleep time);
if( $^O !~ /mswin/i ) {
    require Time::HiRes;
    Time::HiRes->import('ualarm');
}

Log::Log4perl->easy_init($ERROR);

# What instances of Chrome will we try?
my @instances = t::helper::browser_instances();
my $testcount = 33;

if (my $err = t::helper::default_unavailable) {
    plan skip_all => "Couldn't connect to Chrome: $@";
    exit
} else {
    plan tests => $testcount*@instances;
};

sub new_mech {
    t::helper::need_minimum_chrome_version( '62.0.0.0', @_ );
    WWW::Mechanize::Chrome->new(
        autodie => 1,
        @_,
    );
};

t::helper::run_across_instances(\@instances, \&new_mech, $testcount, sub {
    my ($browser_instance, $mech) = @_;

    t::helper::set_watchdog($t::helper::is_slow ? 180 : 60);

    t::helper::safe_get_local($mech, '50-form2.html');
    ok $mech->current_form, "At start, we have a current form";
    t::helper::safe_form_number($mech, 2);
    my $button = t::helper::safe_selector($mech, '#btn_ok', single => 1);
    isa_ok $button, 'WWW::Mechanize::Chrome::Node', "The button image";
    ok t::helper::safe_submit($mech), 'Sent the page';
    ok $mech->current_form, "After a submit, we have a current form";

    t::helper::safe_get_local($mech, '50-form2.html');
    t::helper::safe_form_id($mech, 'snd2');
    ok $mech->current_form, "After setting form_id, We have a current form";
    $mech->sleep(0.1); # why is this here?!
    is $mech->current_form->get_attribute('id'), 'snd2', "We can ask the form with get_attribute(id)";
    my $content = $mech->current_form->get_attribute('innerHTML');
    ok !!$content, "We got content from asking the current form with get_attribute";
    my $backendNodeId = $mech->current_form->backendNodeId;
    ok !!$backendNodeId, "The form has a backendNodeId '$backendNodeId'";
    t::helper::safe_field($mech, 'id', 99);
    pass "We survived setting the field 'id' to 99";
    my $current_form = $mech->current_form;
    ok !!$current_form, "We got a current form";
    my $objectId = $current_form->objectId;
    ok !!$objectId, "The form has an objectId ('$objectId')";
    #like $objectId, qr{injectedScriptId}, "The objectId matches /injectedScriptId/";
    $objectId = $current_form->objectId;
    is $@, '', "No error when retrieving objectId twice";
    ok !!$objectId, "The form still has an objectId ('$objectId')";
    #like $objectId, qr{injectedScriptId}, "The objectId still matches /injectedScriptId/";
    my $content2;
    #eval {
        $content2 = $current_form->get_attribute('innerHTML');
    #};
    is $@, '', "No error when retrieving form HTML";
    ok !!$content2, "We got content from (again) asking the current form with get_attribute";
    isnt $content2, $content, "we managed to change the form by setting the 'id' field";
    is t::helper::safe_xpath($mech, './/*[@name="id"]',
        node => $mech->current_form,
        single => 1)->get_attribute('value', live => 1), 99,
        "We have set field 'id' to '99' in the correct form";

    t::helper::safe_get_local($mech, '50-form2.html');
    note "Selecting form by fields 'r1','r2'";
    t::helper::safe_form_with_fields($mech, 'r1','r2');
    ok $mech->current_form, "We can find a form by its contained input fields";

    t::helper::safe_get_local($mech, '50-form2.html');
    note "Selecting form by name 'snd'";
    t::helper::safe_form_name($mech, 'snd');
    ok $mech->current_form, "We can find a form by its name";
    is $mech->current_form->get_attribute('name'), 'snd', "We can find a form by its name";

    t::helper::safe_get_local($mech, '50-form2.html');
    ok $mech->current_form, "On a new ->get, we have a current form";

    t::helper::safe_get_local($mech, '50-form2.html');
    note "Selecting form by field 'comment'";
    t::helper::safe_form_with_fields($mech, 'comment');
    ok $mech->current_form, "We can find a form by its contained textarea fields";
    t::helper::safe_field($mech, 'comment', "Just another Phrome Hacker,");
    pass "We survived setting the field 'comment' to some JAPH";
    like t::helper::safe_xpath($mech, './/textarea',
        node   => $mech->current_form,
        single => 1)->get_attribute('value'), qr/Just another/,
        "We set textarea and verified it";

    t::helper::safe_get_local($mech, '50-form2.html');
    note "Selecting form by field 'quickcomment'";
    t::helper::safe_form_with_fields($mech, 'quickcomment');
    ok $mech->current_form, "We can find a form by its contained select fields";
    
    note "Setting field 'quickcomment' to 2";
    t::helper::safe_field($mech, 'quickcomment', 2);
    pass "We survived setting the field 'quickcomment' to 2";
    
    $mech->sleep(1) if $^O =~ /mswin/i;
    note "Getting value of 'quickcomment'";
    my @result = t::helper::safe_value($mech, 'quickcomment');
    cmp_bag \@result, [2], "->field returned bag 2";
    # diag explain \@result;

    t::helper::safe_get_local($mech, '50-form2.html');
    note "Selecting form by field 'multic'";
    t::helper::safe_form_with_fields($mech, 'multic');
    ok $mech->current_form, "We can find a form by its contained multi-select fields";
    
    $mech->sleep(1) if $^O =~ /mswin/i;
    note "Getting initial value of 'multic'";
    @result = t::helper::safe_value($mech, 'multic', { all => 1 });
    cmp_bag \@result, [2,2,3], "->field returned bag 2,2,3";
    # diag explain \@result;

    note "Setting multic to 1,2";
    t::helper::safe_field($mech, 'multic', [1,2]);
    pass "We survived setting the field 'multic' to 1,2";
    
    $mech->sleep(1) if $^O =~ /mswin/i;
    note "Verifying set value of 'multic'";
    @result = t::helper::safe_value($mech, 'multic', { all => 1 });
    cmp_bag \@result, [1,1,2,2], "->field returned bag 1,1,2,2";
    # diag explain \@result;

    t::helper::safe_get_local($mech, '50-form2.html');
    note "Selecting form by field 'date'";
    t::helper::safe_form_with_fields($mech, 'date');
    @result = ();
    my $ok = eval {
        t::helper::safe_set_fields($mech, date => ['2020-04-04',2] );
        1;
    };
    is $ok, 1, "We survived setting the second date field"
        or diag $@;
    $mech->sleep(1) if $^O =~ /mswin/i;
    @result = t::helper::safe_value($mech, 'date', 2);
    is_deeply \@result, ['2020-04-04'], "We set the second date field";

    note "End of test sub for $browser_instance";
});

alarm(0);
