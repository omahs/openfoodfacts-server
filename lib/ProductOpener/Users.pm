# This file is part of Product Opener.
#
# Product Opener
# Copyright (C) 2011-2023 Association Open Food Facts
# Contact: contact@openfoodfacts.org
# Address: 21 rue des Iles, 94100 Saint-Maur des Fossés, France
#
# Product Opener is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

=head1 NAME

ProductOpener::Users - manage user profiles and sessions

=head1 SYNOPSIS

C<ProductOpener::Users> contains functions to create and edit user profiles
and to manage user sessions.

    use ProductOpener::Users qw/:all/;

	[..]

	init_user($request_ref);


=head1 DESCRIPTION

[..]

=cut

package ProductOpener::Users;

use ProductOpener::PerlStandards;
use Exporter qw< import >;

BEGIN {
	use vars qw(@ISA @EXPORT_OK %EXPORT_TAGS);
	@EXPORT_OK = qw(
		%User
		$User_id
		%Org
		$Org_id
		$Owner_id

		&check_user_form
		&process_user_form
		&check_edit_owner

		&init_user

		&is_admin_user
		&create_password_hash
		&check_password_hash
		&retrieve_user
		&remove_user_by_org_admin
		&add_users_to_org_by_admin

		&check_session

		&generate_token

	);    # symbols to export on request
	%EXPORT_TAGS = (all => [@EXPORT_OK]);
}

use vars @EXPORT_OK;

use ProductOpener::Store qw/:all/;
use ProductOpener::Config qw/:all/;
use ProductOpener::Paths qw/:all/;
use ProductOpener::Mail qw/:all/;
use ProductOpener::Lang qw/:all/;
use ProductOpener::Display qw/:all/;
use ProductOpener::Orgs qw/:all/;
use ProductOpener::Products qw/:all/;
use ProductOpener::Text qw/:all/;

use CGI qw/:cgi :form escapeHTML/;
use Encode;
use JSON::PP;

use Email::Valid;
use Crypt::PasswdMD5 qw(unix_md5_crypt);
use Math::Random::Secure qw(irand);
use Crypt::ScryptKDF qw(scrypt_hash scrypt_hash_verify);
use Log::Any qw($log);
use MIME::Base32 qw(encode_base32);

my @user_groups = qw(producer database app bot moderator pro_moderator);

# Initialize some constants

my $cookie_name = 'session';
my $cookie_domain = "." . $server_domain;    # e.g. fr.openfoodfacts.org sets the domain to .openfoodfacts.org
$cookie_domain =~ s/\.pro\./\./;    # e.g. .pro.openfoodfacts.org -> .openfoodfacts.org
if (defined $server_options{cookie_domain}) {
	$cookie_domain
		= "." . $server_options{cookie_domain};    # e.g. fr.import.openfoodfacts.org sets domain to .openfoodfacts.org
}

=head1 FUNCTIONS

=head2 generate_token()

C<generate_token()> generates a secure token for the session IDs. More information: https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html#Session_ID_Content_.28or_Value.29

=head3 Return values

Creates a new session ID

=cut

sub generate_token ($name_length) {

	my @chars = ('a' .. 'z', 'A' .. 'Z', 0 .. 9);
	return join '', map {$chars[irand @chars]} 1 .. $name_length;
}

=head2 create_password_hash($password)

Takes $password and hashes it using scrypt

C<create_password_hash()>  This function hashes the user's password using Scrypt which is a salted hashing algorithm. 
Password salting adds a random sequence of data to each password and then hashes it. Password hashing is turning a password into a random string by using some algorithm.

=head3 Arguments

$password : String

=head3 Return values

Returns the salted hashed sequence.

=cut

sub create_password_hash ($password) {

	return scrypt_hash($password);
}

=head2 check_password_hash ($password, $hash)

Turns $password into hash using md5 or scrypt and compares it to $hash.

C<check_password_hash()>  This function takes the hash generated by create_password_hash() and the input password string.
Further, it hashes the input password string md5 or scrypt and verifies if it matches with stored password hash. 
If the stored hash matches the input-password hash, it returns 1. Otherwise, it's a 0.

=head3 Arguments

Takes in 2 string: $password and $hash generated by create_password_hash()

=head3 Return values

Boolean: This function returns a 1/0 (True or False)

=cut

sub check_password_hash ($password, $hash) {

	if ($hash =~ /^\$1\$(?:.*)/) {
		if ($hash eq unix_md5_crypt($password, $hash)) {
			return 1;
		}
		else {
			return 0;
		}
	}
	else {
		return scrypt_hash_verify($password, $hash);
	}
}

# we use user_init() now and not create_user()

=head2 delete_user ($user_ref)

C<delete_user()> Creates a background job to delete the user

=head3 Arguments

Takes in the $user_ref of the user to be deleted

=cut

sub delete_user ($user_ref) {
	my $args_ref = {
		userid => get_string_id_for_lang("no_language", $user_ref->{userid}),
		email => $user_ref->{email},
	};

	require ProductOpener::Producers;
	ProductOpener::Producers::queue_job(delete_user => [$args_ref] => {queue => $server_options{minion_local_queue}});

	return;
}

=head2 delete_user_task ($job, $args_ref)

C<delete_user_task()> Background task that deletes a user. 
This function removes the user files, the email and re-assigns product edits to openfoodfacts-contributors-[random number]

=head3 Arguments

Minion job arguments. $args_ref contains the userid and email

=cut

sub delete_user_task ($job, $args_ref) {
	return if not defined $job;

	my $job_id = $job->{id};

	my $log_message = "delete_user_task - job: $job_id started - args: " . encode_json($args_ref) . "\n";
	open(my $minion_log, ">>", "$BASE_DIRS{LOGS}/minion.log");
	print $minion_log $log_message;
	close($minion_log);

	print STDERR $log_message;

	my $userid = $args_ref->{userid};
	# Suffix is a combination of seconds since epoch plus a 16 bit random number
	my $new_userid = "anonymous-" . lc(encode_base32(pack('LS', time(), rand(65536))));

	$log->info("delete_user", {userid => $userid, new_userid => $new_userid}) if $log->is_info();

	# Remove the user file
	unlink("$BASE_DIRS{USERS}/$userid.sto");

	# Remove the e-mail
	my $emails_ref = retrieve("$BASE_DIRS{USERS}/users_emails.sto");
	my $email = $args_ref->{email};

	if ((defined $email) and ($email =~ /\@/)) {

		if (defined $emails_ref->{$email}) {
			delete $emails_ref->{$email};
			store("$BASE_DIRS{USERS}/users_emails.sto", $emails_ref);
		}
	}

	#  re-assign product edits to anonymous-[random number]
	find_and_replace_user_id_in_products($userid, $new_userid);

	$job->finish("done");

	return;
}

=head2 is_admin_user()

Checks if the user with the passed user ID is an admin or not.

=head3 Arguments

The user ID is passed

=head3 Return values

Boolean: This function returns a 1/0 (True or False)

=cut

sub is_admin_user ($user_id) {

	# %admin is defined in Config.pm
	# admins can change permissions for all users
	return ((%admins) and (defined $user_id) and (exists $admins{$user_id}));
}

=head2 check_user_org($user_ref, $new_org)

This method checks a new org entry for a user.

warning: It has the side effect of already listing user in the org,
and removing it from eventual previous one.
If new_org is empty, user is removed from previous org.

It also creates the org if did not yet exists.

It should be called only by admin.

=head3 Parameters

=head4 User object $user_ref

=head4 String new org name $new_org

=cut

sub check_user_org ($user_ref, $new_org_id) {

	my $previous_org = $user_ref->{org};
	$user_ref->{org} = $new_org_id;
	if ($user_ref->{org} ne "") {
		$user_ref->{org_id} = get_string_id_for_lang("no_language", $user_ref->{org});
		# Admin field for org overrides the requested org field
		delete $user_ref->{requested_org};
		delete $user_ref->{requested_org_id};

		my $org_ref = retrieve_or_create_org($User_id, $user_ref->{org});

		add_user_to_org($org_ref, $user_ref->{userid}, ["admins", "members"]);
	}
	else {
		# user has no org
		delete $user_ref->{org};
		delete $user_ref->{org_id};
	}

	# eventually remove from previous org
	if ((defined $previous_org) and ($previous_org ne "") and ($previous_org ne $user_ref->{org})) {
		my $org_ref = retrieve_org($previous_org);
		if (defined $org_ref) {
			remove_user_from_org($org_ref, $user_ref->{userid}, ["admins", "members"]);
		}
	}
	return;
}

=head2 check_user_form($type, $user_ref, $errors_ref)

C<check_user_form()> This method checks and validates the different entries in the user form.
It also handles Spam-usernames, fields for the organization accounts.

This will then be used in process_user_form

=head3 Parameters

=head4 String action type $type
edit / add / delete

=head4 User object $user_ref

=head4 Array to report errors $errors_ref

=cut

sub check_user_form ($type, $user_ref, $errors_ref) {

	# Removing the tabs, spaces and white space characters
	# Assigning 'userid' to 0 -- if userid is not defined
	$user_ref->{userid} = remove_tags_and_quote(single_param('userid'));

	# Allow for sending the 'name' & 'email' as a form parameter instead of a HTTP header, as web based apps may not be able to change the header sent by the browser
	$user_ref->{name} = remove_tags_and_quote(decode utf8 => single_param('name'));
	my $email = remove_tags_and_quote(decode utf8 => single_param('email'));

	$log->debug("check_user_form", {type => $type, user_ref => $user_ref, email => $email}) if $log->is_debug();

	if ((defined $email) and ($email ne '') and ($user_ref->{email} ne $email)) {

		# check that the email is not already used
		my $emails_ref = retrieve("$BASE_DIRS{USERS}/users_emails.sto");
		if ((defined $emails_ref->{$email}) and ($emails_ref->{$email}[0] ne $user_ref->{userid})) {
			$log->debug("check_user_form - email already in use",
				{type => $type, email => $email, existing_userid => $emails_ref->{$email}})
				if $log->is_debug();
			push @{$errors_ref}, $Lang{error_email_already_in_use}{$lang};
		}

		# Keep old email until the user is saved
		$user_ref->{old_email} = $user_ref->{email};
		$user_ref->{email} = $email;
	}

	# Is there a checkbox to make a professional account
	if (defined single_param("pro_checkbox")) {

		if (single_param("pro")) {
			$user_ref->{pro} = 1;

			# user request to be part of an org, this submission will be validated later on
			if (defined single_param("requested_org")) {
				$user_ref->{requested_org} = remove_tags_and_quote(decode utf8 => single_param("requested_org"));

				my $requested_org_id = get_string_id_for_lang("no_language", $user_ref->{requested_org});

				if ($requested_org_id ne "") {
					$user_ref->{requested_org_id} = $requested_org_id;
				}
				else {
					push @{$errors_ref}, "error_missing_org";
				}
			}
			else {
				delete $user_ref->{requested_org_id};
			}
		}
		else {
			delete $user_ref->{pro};
			delete $user_ref->{requested_org_id};
		}
	}

	if ($type eq 'add') {
		$user_ref->{newsletter} = remove_tags_and_quote(single_param('newsletter'));
		$user_ref->{discussion} = remove_tags_and_quote(single_param('discussion'));
		$user_ref->{ip} = remote_addr();
		$user_ref->{initial_lc} = $lc;
		$user_ref->{initial_cc} = $cc;
		$user_ref->{initial_user_agent} = user_agent();
	}

	if ($admin) {

		# Org
		check_user_org($user_ref, remove_tags_and_quote(decode utf8 => single_param('org')));

		# Permission groups (moderator, producer moderator, etc.)
		foreach my $group (@user_groups) {
			$user_ref->{$group} = remove_tags_and_quote(single_param("user_group_$group"));
		}
	}

	defined $user_ref->{registered_t} or $user_ref->{registered_t} = time();

	for (my $i = 1; $i <= 3; $i++) {
		if (defined single_param('team_' . $i)) {
			$user_ref->{'team_' . $i} = remove_tags_and_quote(decode utf8 => single_param('team_' . $i));
			$user_ref->{'team_' . $i} =~ s/\&lt;/ /g;
			$user_ref->{'team_' . $i} =~ s/\&gt;/ /g;
			$user_ref->{'team_' . $i} =~ s/\&quot;/"/g;
		}
	}

	# contributor settings
	$user_ref->{display_barcode} = !!remove_tags_and_quote(single_param("display_barcode"));
	$user_ref->{edit_link} = !!remove_tags_and_quote(single_param("edit_link"));

	# Check for spam
	# e.g. name with "Lydia want to meet you! Click here:" + an url

	foreach my $bad_string ('click here', 'wants to meet you', '://') {
		if ($user_ref->{name} =~ /$bad_string/i) {
			# log the ip
			open(my $log, ">>", "$BASE_DIRS{LOGS}/user_spam.log");
			print $log remote_addr() . "\t" . time() . "\t" . $user_ref->{name} . "\n";
			close($log);
			# bail out, return 200 status code
			display_error_and_exit("", 200);
		}
	}

	# Check input parameters, redisplay if necessary

	if (length($user_ref->{name}) < 2) {
		push @{$errors_ref}, $Lang{error_no_name}{$lang};
	}
	elsif (length($user_ref->{name}) > 60) {
		push @{$errors_ref}, $Lang{error_name_too_long}{$lang};
	}

	my $address;
	eval {$address = Email::Valid->address(-address => $user_ref->{email}, -mxcheck => 1);};
	$address = 0 if $@;
	if (not $address) {
		push @{$errors_ref}, $Lang{error_invalid_email}{$lang};
	}
	else {
		# If all checks have passed, reinitialize with modified email
		$user_ref->{email} = $address;
	}

	if ($type eq 'add') {

		my $userid = get_string_id_for_lang("no_language", $user_ref->{userid});

		if (length($user_ref->{userid}) < 2) {
			push @{$errors_ref}, $Lang{error_no_username}{$lang};
		}
		elsif (-e "$BASE_DIRS{USERS}/$userid.sto") {
			push @{$errors_ref}, $Lang{error_username_not_available}{$lang};
		}
		elsif ($user_ref->{userid} !~ /^[a-z0-9]+[a-z0-9\-]*[a-z0-9]+$/) {
			push @{$errors_ref}, $Lang{error_invalid_username}{$lang};
		}
		elsif (length($user_ref->{userid}) > 20) {
			push @{$errors_ref}, $Lang{error_username_too_long}{$lang};
		}

		if (length(decode utf8 => single_param('password')) < 6) {
			push @{$errors_ref}, $Lang{error_invalid_password}{$lang};
		}
	}

	if (param('password') ne single_param('confirm_password')) {
		push @{$errors_ref}, $Lang{error_different_passwords}{$lang};
	}
	elsif (single_param('password') ne '') {
		$user_ref->{encrypted_password} = create_password_hash(encode_utf8(decode utf8 => single_param('password')));
	}

	return;
}

=head2 notify_user_requested_org($user_ref, $org_created)

Notify admin that a user requested to be part of an org

=head3 Parameters

=head4 User object $user_ref

=head4 boolean $org_created

Is the org newly created ?

=cut

sub notify_user_requested_org ($user_ref, $org_created) {

	# the template for the email, we will build it gradually
	my $template_data_ref = {
		userid => $user_ref->{userid},
		user => $user_ref,
		requested_org => $user_ref->{requested_org_id},
	};

	# construct first part of the mail about new pro account
	my $mail = '';
	process_template("emails/user_new_pro_account.tt.txt", $template_data_ref, \$mail);
	if ($mail =~ /^\s*Subject:\s*(.*)\n/im) {
		my $subject = $1;
		my $body = $';
		$body =~ s/^\n+//;
		$template_data_ref->{mail_subject_new_pro_account} = URI::Escape::XS::encodeURIComponent($subject);
		$template_data_ref->{mail_body_new_pro_account} = URI::Escape::XS::encodeURIComponent($body);
	}
	else {
		send_email_to_producers_admin("Error - broken template: emails/user_new_pro_account.tt.txt",
			"Missing Subject line:\n\n" . $mail);
	}

	if (not $org_created) {
		# The requested org already exists
		# build second part of the mail about it and alter the subject
		$mail = '';
		process_template("emails/user_new_pro_account_org_request_validated.tt.txt", $template_data_ref, \$mail);
		if ($mail =~ /^\s*Subject:\s*(.*)\n/im) {
			my $subject = $1;
			my $body = $';
			$body =~ s/^\n+//;
			$template_data_ref->{mail_subject_new_pro_account_org_request_validated}
				= URI::Escape::XS::encodeURIComponent($subject);
			$template_data_ref->{mail_body_new_pro_account_org_request_validated}
				= URI::Escape::XS::encodeURIComponent($body);
		}
		else {
			send_email_to_producers_admin(
				"Error - broken template: emails/user_new_pro_account_org_request_validated.tt.txt",
				"Missing Subject line:\n\n" . $mail);
		}
	}

	# Send an e-mail notification to admins, with links to the organization
	$mail = '';
	process_template("emails/user_new_pro_account_admin_notification.tt.html", $template_data_ref, \$mail);
	if ($mail =~ /^\s*Subject:\s*(.*)\n/im) {
		my $subject = $1;
		my $body = $';
		$body =~ s/^\n+//;
		send_email_to_producers_admin($subject, $body);
	}
	else {
		send_email_to_producers_admin("Error - broken template: emails/user_new_pro_account_admin_notification.tt.html",
			"Missing Subject line:\n\n" . $mail);
	}
	return;
}

=head2 process_user_requested_org($user_ref)

A user requested to be part of a producer organization.
Process it.

=head3 Parameters

=head4 User object $user_ref

=cut

sub process_user_requested_org ($user_ref) {

	(defined $user_ref->{requested_org_id}) or return 1;

	my $userid = $user_ref->{userid};
	my $org_created = 0;
	my $requested_org_ref = retrieve_org($user_ref->{requested_org_id});

	if (not(defined $requested_org_ref)) {
		# The requested org does not exist, create it
		my $org_ref = create_org($userid, $user_ref->{requested_org});
		add_user_to_org($org_ref, $userid, ["admins", "members"]);

		$user_ref->{org} = $user_ref->{requested_org_id};
		$user_ref->{org_id} = get_string_id_for_lang("no_language", $user_ref->{org});

		delete $user_ref->{requested_org};
		delete $user_ref->{requested_org_id};

		$org_created = 1;
	}
	# send a notification to admins
	notify_user_requested_org($user_ref, $org_created);
	return 1;
}

=head2 process_user_form($type, $user_ref, $request_ref)

Process user form.

To be used after check_user_form

=head3 Parameters

=head4 String action type $type
edit / add / delete

=head4 User object $user_ref

=head4 Request object $request_ref

=cut

sub process_user_form ($type, $user_ref, $request_ref) {

	my $userid = $user_ref->{userid};
	my $error = 0;

	$log->debug("process_user_form", {type => $type, user_ref => $user_ref}) if $log->is_debug();

	# Professional account with a requested org (existing or new)
	process_user_requested_org($user_ref);

	# save user
	store("$BASE_DIRS{USERS}/$userid.sto", $user_ref);

	# Update email
	my $emails_ref = retrieve("$BASE_DIRS{USERS}/users_emails.sto");
	my $email = $user_ref->{email};

	if ((defined $email) and ($email =~ /\@/)) {
		$emails_ref->{$email} = [$userid];
	}
	if (defined $user_ref->{old_email}) {
		delete $emails_ref->{$user_ref->{old_email}};
		delete $user_ref->{old_email};
	}
	store("$BASE_DIRS{USERS}/users_emails.sto", $emails_ref);

	if ($type eq 'add') {

		# Initialize the session to send a session cookie back
		# so that newly created users do not have to login right after

		param("user_id", $userid);
		init_user($request_ref);

		# Fetch the HTML mail template corresponding to the user language, english is the
		# default if the translation is not available
		my $email_content = get_html_email_content("user_welcome.html", $user_ref->{initial_lc});
		my $user_name = $user_ref->{name};
		# Replace placeholders by user values
		$email_content =~ s/\{\{USERID\}\}/$userid/g;
		$email_content =~ s/\{\{NAME\}\}/$user_name/g;
		$error = send_html_email($user_ref, lang("add_user_email_subject"), $email_content);

		my $admin_mail_body = <<EMAIL

Bonjour,

Inscription d'un utilisateur :

name: $user_ref->{name}
email: $user_ref->{email}
twitter: https://twitter.com/$user_ref->{twitter}
newsletter: $user_ref->{newsletter}
discussion: $user_ref->{discussion}
lc: $user_ref->{initial_lc}
cc: $user_ref->{initial_cc}

EMAIL
			;
		$error += send_email_to_admin("Inscription de $userid", $admin_mail_body);
	}
	return $error;
}

=head2 check_edit_owner($user_ref, $errors_ref)

This sets pro_moderator_owner according to request parameter.
Sets it in $User global and $user_ref.

This variable is used to say that a moderator or admin
is acting on the pro platform as part of a specific company.

=head3 Arguments

=head4 User object $user_ref

=head4 array to collect errors $errors_ref

=cut

sub check_edit_owner ($user_ref, $errors_ref) {

	# temporarily use the org passed as parameter
	$user_ref->{pro_moderator_owner}
		= get_string_id_for_lang("no_language", remove_tags_and_quote(single_param('pro_moderator_owner')));

	# If the owner id looks like a GLN, see if we have a corresponding org

	if ($user_ref->{pro_moderator_owner} =~ /^\d+$/) {
		my $glns_ref = retrieve("$BASE_DIRS{ORGS}/orgs_glns.sto");
		not defined $glns_ref and $glns_ref = {};
		if (defined $glns_ref->{$user_ref->{pro_moderator_owner}}) {
			$user_ref->{pro_moderator_owner} = $glns_ref->{$user_ref->{pro_moderator_owner}};
		}
	}

	$log->debug("check_edit_owner", {pro_moderator_owner => $User{pro_moderator_owner}}) if $log->is_debug();

	if ((not defined $user_ref->{pro_moderator_owner}) or ($user_ref->{pro_moderator_owner} eq "")) {
		delete $user_ref->{pro_moderator_owner};
		# Also edit the current user object so that we can display the current status directly on the form result page
		delete $User{pro_moderator_owner};
	}
	elsif ($user_ref->{pro_moderator_owner} =~ /^user-/) {
		my $userid = $';
		# Add check that organization exists when we add org profiles

		if (!-e "$BASE_DIRS{USERS}/$userid.sto") {
			push @{$errors_ref}, sprintf($Lang{error_user_does_not_exist}{$lang}, $userid);
		}
		else {
			$User{pro_moderator_owner} = $user_ref->{pro_moderator_owner};
			$log->debug("set pro_moderator_owner (user)",
				{userid => $userid, pro_moderator_owner => $User{pro_moderator_owner}})
				if $log->is_debug();
		}
	}
	elsif ($user_ref->{pro_moderator_owner} eq 'all') {
		# Admin mode to see all products from all owners
		$User{pro_moderator_owner} = $user_ref->{pro_moderator_owner};
		$log->debug(
			"set pro_moderator_owner (all) see products from all owners",
			{pro_moderator_owner => $User{pro_moderator_owner}}
		) if $log->is_debug();
	}
	elsif ($user_ref->{pro_moderator_owner} =~ /^org-/) {
		my $orgid = $';
		$User{pro_moderator_owner} = $user_ref->{pro_moderator_owner};
		$log->debug("set pro_moderator_owner (org)",
			{orgid => $orgid, pro_moderator_owner => $User{pro_moderator_owner}})
			if $log->is_debug();
	}
	else {
		# if there is no user- or org- prefix, assume it is an org
		my $orgid = $user_ref->{pro_moderator_owner};
		$User{pro_moderator_owner} = "org-" . $orgid;
		$user_ref->{pro_moderator_owner} = "org-" . $orgid;
		$log->debug("set pro_moderator_owner (org)",
			{orgid => $orgid, pro_moderator_owner => $User{pro_moderator_owner}})
			if $log->is_debug();
	}

	return;
}

=head2 migrate_password_hash($user_ref)

We used to use crypt instead of scrypt to store hashed passwords.
If the user is logging in with a correct password, we can update the password hash.

=head3 Arguments

=head4 User object $user_ref

=cut

sub migrate_password_hash ($user_ref) {

	# Migration: take the occasion of having password to upgrade to scrypt, if it is still in crypt format
	if ($user_ref->{'encrypted_password'} =~ /^\$1\$(?:.*)/) {
		$user_ref->{'encrypted_password'} = create_password_hash(encode_utf8(decode utf8 => single_param('password')));
		$log->info("crypt password upgraded to scrypt_hash") if $log->is_info();
	}
	return;
}

=head2 remove_old_sessions($user_ref)

Remove the oldest session if we have too many sessions opened for an user.

=head3 Arguments

=head4 User object $user_ref

=cut

sub remove_old_sessions ($user_ref) {

	# Maximum number sessions to store for a given user in sto file
	my $max_session = 10;

	# Check if we need to delete the oldest session
	# delete $user_ref->{'user_session'};
	if ((scalar keys %{$user_ref->{'user_sessions'}}) >= $max_session) {
		my %user_session_stored = %{$user_ref->{'user_sessions'}};

		# Find the older session and remove it
		my @session_by_time
			= sort {$user_session_stored{$a}{'time'} <=> $user_session_stored{$b}{'time'}} (keys %user_session_stored);

		while (($#session_by_time + 1) > $max_session) {
			my $oldest_session = shift @session_by_time;
			delete $user_ref->{'user_sessions'}{$oldest_session};
		}
	}
	return;
}

=head2 generate_session_cookie($user_id, $user_session)

Generate a session cookie.

=head3 Arguments

=head4 User id $user_id

=head4 Session token $user_session

=head3 Return values

Session cookie.

=cut

sub generate_session_cookie ($user_id, $user_session) {

	my $length = 0;

	if ((defined single_param('length')) and (single_param('length') > 0)) {
		$length = single_param('length');
	}
	elsif ((defined single_param('remember_me')) and (single_param('remember_me') eq 'on')) {
		$length = 31536000 * 10;
	}

	my $session_ref = {'user_id' => $user_id, 'user_session' => $user_session};

	# generate session cookie
	my $cookie_ref = {
		'-name' => $cookie_name,
		'-value' => $session_ref,
		'-path' => '/',
		'-domain' => $cookie_domain,
		'-samesite' => 'Lax',
	};

	if ($length > 0) {
		# Set a persistent cookie
		$log->debug("setting persistent cookie") if $log->is_debug();
		$cookie_ref->{'-expires'} = '+' . $length . 's';
	}
	else {
		# Set a session cookie
		$log->debug("setting session cookie") if $log->is_debug();
	}

	return cookie(%$cookie_ref);
}

=head2 open_user_session($user_ref, $request_ref)

Open a session, store it in the user object, and return a cookie with the session id in the request object.

=head3 Arguments

=head4 User object $user_ref

=head4 Request object $request_ref

=head3 Return values

The cookie is returned in $request_ref

=cut

sub open_user_session ($user_ref, $request_ref) {

	my $user_id = $user_ref->{'userid'};

	# Generate a secure session key, store the cookie
	my $user_session = generate_token(64);
	$log->context->{user_session} = $user_session;

	defined $user_ref->{'user_sessions'} or $user_ref->{'user_sessions'} = {};

	remove_old_sessions($user_ref);

	# Store the ip and time corresponding to the given session
	$user_ref->{'user_sessions'}{$user_session} = {
		ip => remote_addr(),
		time => time()
	};

	# Store user data
	my $user_file = "$BASE_DIRS{USERS}/" . get_string_id_for_lang("no_language", $user_id) . ".sto";
	store($user_file, $user_ref);

	$log->debug("session initialized and user info stored") if $log->is_debug();

	$request_ref->{cookie} = generate_session_cookie($user_id, $user_session);

	return;
}

sub retrieve_user ($user_id) {
	my $user_file = "$BASE_DIRS{USERS}/" . get_string_id_for_lang("no_language", $user_id) . ".sto";
	my $user_ref;
	if (-e $user_file) {
		$user_ref = retrieve($user_file);
	}
	return $user_ref;
}

sub is_email_has_off_account ($email) {

	# First, check if the email exists in the users_emails.sto file
	my $emails_ref = retrieve("$data_root/users/users_emails.sto");

	if (defined $emails_ref->{$email}) {
		my $user_id = $emails_ref->{$email}[0];

		# Next, check if the user file exists and has the 'userid' field
		my $user_file = "$data_root/users/" . get_string_id_for_lang("no_language", $user_id) . ".sto";
		if (-e $user_file) {
			my $user_ref = retrieve($user_file);
			return $user_ref->{userid} if defined $user_ref->{userid};
		}
	}

	return;    # Email is not associated with an OFF account
}

sub remove_user_by_org_admin ($orgid, $user_id) {
	my $groups_ref = ['admins', 'members'];
	remove_user_from_org($orgid, $user_id, $groups_ref);

	# Reset the 'org' field of the user
	my $user_ref = retrieve_user($user_id);
	delete $user_ref->{org};
	delete $user_ref->{org_id};
	my $user_file = "$BASE_DIRS{USERS}/" . get_string_id_for_lang("no_language", $user_id) . ".sto";
	store($user_file, $user_ref);
	return;
}

sub add_users_to_org_by_admin ($org_id, $email_list) {

	my @emails_added;
	my @emails_invited;

	# Convert the email_list into an array of email addresses
	my @emails = split(/,\s*/, $email_list);

	foreach my $email (@emails) {

		# Check if the email is associated with an OpenFoodFacts account
		my $user_id = is_email_has_off_account($email);
		if (defined $user_id) {
			# Add the user to the organization
			add_user_to_org($org_id, $user_id, ["members"]);
			push @emails_added, $email;
		}
		else {

			push @emails_invited, $email;

		}
	}
	my $email_ref = {
		added => \@emails_added,
		invited => \@emails_invited,
	};
	$log->debug("The list of email ids ", {emails_list => $email_ref}) if $log->is_debug();

	return $email_ref;
}

sub init_user ($request_ref) {

	my $user_id = undef;
	my $user_ref = undef;
	my $org_ref = undef;

	$User_id = undef;
	$Org_id = undef;
	%User = ();
	%Org = ();

	# Remove persistent cookie if user is logging out
	if ((defined request_param($request_ref, 'length')) and (request_param($request_ref, 'length') eq 'logout')) {
		$log->debug("user logout") if $log->is_debug();
		my $session = {};
		$request_ref->{cookie} = cookie(
			-name => $cookie_name,
			-expires => '-1d',
			-value => $session,
			-path => '/',
			-domain => "$cookie_domain"
		);
	}

	# Retrieve user_id and password from form parameters
	elsif ( (defined request_param($request_ref, 'user_id'))
		and (request_param($request_ref, 'user_id') ne '')
		and (((defined request_param($request_ref, 'password')) and (request_param($request_ref, 'password') ne ''))))
	{

		$user_id = remove_tags_and_quote(request_param($request_ref, 'user_id'));

		if ($user_id =~ /\@/) {
			$log->info("got email while initializing user", {email => $user_id}) if $log->is_info();
			my $emails_ref = retrieve("$BASE_DIRS{USERS}/users_emails.sto");
			if (not defined $emails_ref->{$user_id}) {
				# not found, try with lower case email
				$user_id = lc $user_id;
			}
			if (not defined $emails_ref->{$user_id}) {
				$user_id = undef;
				$log->info("Unknown user e-mail", {email => $user_id}) if $log->is_info();
				# Trigger an error
				return ($Lang{error_bad_login_password}{$lang});
			}
			else {
				my @userids = @{$emails_ref->{$user_id}};
				$user_id = $userids[0];
			}

			$log->info("corresponding user_id", {userid => $user_id}) if $log->is_info();
		}

		$log->context->{user_id} = $user_id;
		$log->debug("user_id is defined") if $log->is_debug();
		my $session = undef;

		# If the user exists
		if (defined $user_id) {

			my $user_file = "$BASE_DIRS{USERS}/" . get_string_id_for_lang("no_language", $user_id) . ".sto";

			if (-e $user_file) {
				$user_ref = retrieve($user_file);
				$user_id = $user_ref->{'userid'};
				$log->context->{user_id} = $user_id;

				my $hash_is_correct
					= check_password_hash(encode_utf8(decode utf8 => request_param($request_ref, 'password')),
					$user_ref->{'encrypted_password'});
				# We don't have the right password
				if (not $hash_is_correct) {
					$user_id = undef;
					$log->info(
						"bad password - input does not match stored hash",
						{encrypted_password => $user_ref->{'encrypted_password'}}
					) if $log->is_info();
					# Trigger an error
					return ($Lang{error_bad_login_password}{$lang});
				}
				# We have the right login/password
				elsif (
					not defined request_param($request_ref, 'no_log')) # no need to store sessions for internal requests
				{
					$log->info("correct password for user provided") if $log->is_info();

					migrate_password_hash($user_ref);

					open_user_session($user_ref, $request_ref);
				}
			}
			else {
				$user_id = undef;
				$log->info("bad user") if $log->is_info();
				# Trigger an error
				return ($Lang{error_bad_login_password}{$lang});
			}
		}
	}

	# Retrieve user_id and session from cookie
	elsif ((defined cookie($cookie_name))
		or ((defined single_param('user_session')) and (defined single_param('user_id'))))
	{
		my $user_session;
		if (defined single_param('user_session')) {
			$user_session = single_param('user_session');
			$user_id = single_param('user_id');
			$log->debug("user_session parameter found", {user_id => $user_id, user_session => $user_session})
				if $log->is_debug();
		}
		else {
			my %session = cookie($cookie_name);
			$user_session = $session{'user_session'};
			$user_id = $session{'user_id'};
			$log->debug("session cookie found", {user_id => $user_id, user_session => $user_session})
				if $log->is_debug();
		}

		if (defined $user_id) {
			my $user_file = "$BASE_DIRS{USERS}/" . get_string_id_for_lang("no_language", $user_id) . ".sto";

			if (-e $user_file) {
				$user_ref = retrieve($user_file);
				$log->debug(
					"initializing user",
					{
						user_id => $user_id,
						user_session => $user_session,
						stock_session => $user_ref->{'user_sessions'},
						stock_ip => $user_ref->{'user_last_ip'},
						current_ip => remote_addr()
					}
				) if $log->is_debug();

				# Try to keep sessions opened for users with dynamic IPs
				my $short_ip = sub ($) {
					my $ip = shift;
					# Remove the last two bytes
					$ip =~ s/(\.\d+){2}$//;
					return $ip;
				};

				if (   (not defined $user_ref->{'user_sessions'})
					or (not defined $user_session)
					or (not defined $user_ref->{'user_sessions'}{$user_session}))
					# disable the restriction of sessions by ip address (issue 6842 57E0 C2C7 F629 E4CE 5605 42)
					#	or (not is_ip_known_or_whitelisted($user_ref, $user_session, remote_addr(), $short_ip)))
				{
					$log->debug("no matching session for user") if $log->is_debug();
					$user_id = undef;
					$user_ref = undef;
					# Remove the cookie
					my $session = {};
					$request_ref->{cookie} = cookie(
						-name => $cookie_name,
						-expires => '-1d',
						-value => $session,
						-path => '/',
						-domain => "$cookie_domain"
					);
				}
				else {
					$log->debug("user identified", {user_id => $user_id, stocked_user_id => $user_ref->{'userid'}})
						if $log->is_debug();
					$user_id = $user_ref->{'userid'};
				}
			}
			else {
				# Remove the cookie
				my $session = {};
				$request_ref->{cookie} = cookie(
					-name => $cookie_name,
					-expires => '-1d',
					-value => $session,
					-path => '/',
					-domain => "$cookie_domain"
				);

				$user_id = undef;
			}
		}
		else {
			# Remove the cookie
			my $session = {};
			$request_ref->{cookie} = cookie(
				-name => $cookie_name,
				-expires => '-1d',
				-value => $session,
				-path => '/',
				-domain => "$cookie_domain"
			);

			$user_id = undef;
		}
	}
	else {
		$log->info("no user found") if $log->is_info();
	}

	$log->debug("cookie", {user_id => $user_id, cookie => $request_ref->{cookie}}) if $log->is_debug();

	$User_id = $user_id;
	if (defined $user_ref) {
		%User = %{$user_ref};
	}
	else {
		%User = ();
	}

	# Load the user org profile

	if (defined $user_ref->{org_id}) {
		$Org_id = $user_ref->{org_id};
		$org_ref = retrieve_or_create_org($User_id, $Org_id);
	}

	if (defined $Org_id) {
		%Org = %{$org_ref};
	}
	else {
		%Org = ();
	}

	# if products are private, select the owner used to restrict the product set with the owners_tags field
	if ((defined $server_options{private_products}) and ($server_options{private_products})) {

		# Producers platform moderators can set the owner to any user or organization
		if (($User{pro_moderator}) and (defined $User{pro_moderator_owner})) {
			$Owner_id = $User{pro_moderator_owner};

			if ($Owner_id =~ /^org-/) {
				$Org_id = $';
				%Org = (org => $Org_id, org_id => $Org_id);
			}
			elsif ($Owner_id =~ /^user-/) {
				$Org_id = undef;
				%Org = ();
			}
			elsif ($Owner_id eq 'all') {
				$Org_id = undef;
				%Org = ();
			}
			else {
				$Owner_id = undef;
			}
		}
		elsif (defined $Org_id) {
			$Owner_id = "org-" . $Org_id;
		}
		elsif (defined $User_id) {
			$Owner_id = "user-" . $User_id;
		}
		else {
			$Owner_id = undef;
		}
	}
	else {
		$Owner_id = undef;
	}

	return 0;
}

=head2 is_ip_known_or_whitelisted ()

This sub introduces a server option to whitelist IPs for all cookies.

=cut

sub is_ip_known_or_whitelisted ($user_ref, $user_session, $ip, $shorten_ip) {

	my $short_ip = $shorten_ip->($ip);

	if (    (defined $user_ref->{'user_sessions'}{$user_session}{'ip'})
		and ($shorten_ip->($user_ref->{'user_sessions'}{$user_session}{'ip'}) eq $short_ip))
	{
		return 1;
	}

	if (defined $server_options{ip_whitelist_session_cookie}) {
		foreach (@{$server_options{ip_whitelist_session_cookie}}) {
			if ($_ eq $ip) {
				return 1;
			}
		}
	}

	return 0;
}

sub check_session ($user_id, $user_session) {

	$log->debug("checking session", {user_id => $user_id, users_session => $user_session}) if $log->is_debug();

	my $user_file = "$BASE_DIRS{USERS}/" . get_string_id_for_lang("no_language", $user_id) . ".sto";

	my $results_ref = {};

	if (-e $user_file) {
		my $user_ref = retrieve($user_file);

		if (defined $user_ref) {
			$log->debug(
				"comparing session with stored user",
				{
					user_id => $user_id,
					user_session => $user_session,
					stock_session => $user_ref->{'user_sessions'},
					stock_ip => $user_ref->{'user_last_ip'},
					current_ip => remote_addr()
				}
			) if $log->is_debug();

			if (
				   (not defined $user_ref->{'user_sessions'})
				or (not defined $user_session)
				or (not defined $user_ref->{'user_sessions'}{$user_session})
				# or (not defined $user_ref->{'user_sessions'}{$user_session}{'ip'})
				# or (($short_ip->($user_ref->{'user_sessions'}{$user_session}{'ip'}) ne ($short_ip->(remote_addr())))

				)
			{
				$log->debug("no matching session for user") if $log->is_debug();
				$user_id = undef;

			}
			else {
				# Get actual user_id (i.e. BIZ or biz -> Biz)
				$log->debug("user identified", {user_id => $user_id, stocked_user_id => $user_ref->{'userid'}})
					if $log->is_debug();

				$user_id = $user_ref->{'userid'};
				$results_ref->{name} = $user_ref->{name};
				$results_ref->{email} = $user_ref->{email};
			}
		}
		else {
			$log->info("could not load user", {user_id => $user_id}) if $log->is_info();
		}

	}
	else {
		$log->info("user does not exist", {user_id => $user_id}) if $log->is_info();
		$user_id = undef;
	}

	$results_ref->{user_id} = $user_id;

	return $results_ref;
}

1;
