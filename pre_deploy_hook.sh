#!/usr/bin/env perl
use strict;
use warnings;
use Cwd "abs_path";
use JSON;
# # # # # CONFIG
my $BASE_DIR    = abs_path(__FILE__."/../..");
my $APP_DIR     = "$BASE_DIR/app";
my $LAMBDA_DIR  = "$BASE_DIR/lambda";
my $MODELS_DIR  = "$BASE_DIR/models";
my @REGIONS     = undef;
my $JSON        = JSON->new->pretty;
my %BUILD_TOOL;
my @BUILD_TOOLS = (
    {
        name            => 'gradle',
        build_file      => 'build.gradle',
        build_commands  => ['gradle createLambda'],
        flavours        => [
            {
                name        => 'wrapper',
                if          => sub { -f "$APP_DIR/gradlew" },
                transform   => sub {
                    $_ =~ s/gradle/.\/gradlew/ for(@{$_[0]->{build_commands}});
                }
            }
        ],
    },
    {
        name            => 'maven',
        build_file      => 'pom.xml',
        build_commands  => ['mvn package'],
        copy_commands   => [
            "mkdir -p $LAMBDA_DIR/base",
            "cp -r target/lib         $LAMBDA_DIR/base/",
            "cp -r target/classes/*   $LAMBDA_DIR/base/", # Resources are also in this folder
        ],
        flavours        => [
            {
                name        => 'wrapper',
                if          => sub { -f "$APP_DIR/mvnw" },
                transform   => sub {
                    $_ =~ s/mvn/.\/mvnw/ for(@{$_[0]->{build_commands}});
                }
            }
        ],
    },
);
# # # # # SUB DECLARATIONS
sub copyAppToLambda;
sub scriptDie(@);
sub execOrDie($);
sub setupModels;
sub setup();
# # # # # MAIN
setup();
copyAppToLambda();
setupModels();
# # # # # SUBS
sub setup(){
    # Get regions needed
    my $askConfig = $JSON->decode(do {
        open my $fh, "<", '.ask/config' or die "$!\n";
        local $/;
        <$fh>;
    });
    my %allRegions = map {
        $_->{awsRegion}, 1
    } @{$askConfig->{deploy_settings}->{default}->{resources}->{lambda}};
    @REGIONS = sort keys %allRegions;
    $APP_DIR = $BASE_DIR unless -d $APP_DIR;
    for my $tool(@BUILD_TOOLS){
        if(-f "$APP_DIR/$tool->{build_file}"){
            %BUILD_TOOL = (%{$tool});
            for my $f(@{$BUILD_TOOL{flavours}}){
                if($f->{if}->()){
                    $BUILD_TOOL{flavour} = $f->{name};
                    $f->{transform}->(\%BUILD_TOOL);
                }
            }
            last;
        }
    }
    if(! %BUILD_TOOL){
        scriptDie("Could not find which build tool you are using.",
                  "Available tools are: ".join(", ", map { $_->{name} } @BUILD_TOOLS));
    }
    logg(
        "USING BUILD TOOL: $BUILD_TOOL{name} (".($BUILD_TOOL{flavour} || 'vanilla').")",
        "USING APP DIR   : $APP_DIR",
    );
}
sub copyAppToLambda {
    logg("Building App (".join('|', @{$BUILD_TOOL{build_commands}}).")");
    chdir $APP_DIR;
    execOrDie($_) for @{$BUILD_TOOL{build_commands}};
    if($BUILD_TOOL{copy_commands}){
        logg("Copying App to Lambda");
        rm_tree $LAMBDA_DIR;
        execOrDie($_) for @{$BUILD_TOOL{copy_commands}};
    }
    for my $region(@REGIONS){
        next if(-s "$LAMBDA_DIR/$region");
        symlink "$LAMBDA_DIR/base", "$LAMBDA_DIR/$region" or die "$!\n";
    }
}
sub setupModels {
    my $baseFile = "$MODELS_DIR/base.json";
    open my $fh, "<", $baseFile or die "$!";
    my $json = "";
    $json .= $_ for <$fh>;
    close $fh or die "$!";
    my $baseModel = $JSON->decode($json);
    for my $locale("en-GB", "en-US"){ # TODO: locale
        open $fh, ">", "$MODELS_DIR/${locale}.json" or die "$!";
        print $fh $JSON->encode($baseModel);
        close $fh or die "$!";
    }
}
# # # # # UTIL SUBS
sub scriptDie(@){
    print "ERROR: $_\n" for @_;
    exit 1;
}
sub execOrDie($){
    my $command = shift;
    my @log = `$command 2>&1`;
    my $exit = $? >> 8;
    chomp for @log;
    if($exit){
        scriptDie "Command failed: $command", @log;
    }
    return @log;
}
sub logg(@){
    print "SCRIPT: $_\n" for @_;
}
