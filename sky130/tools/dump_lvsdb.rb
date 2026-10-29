# Dump KLayout LVS DB circuits and mismatch information.
path = $file || ARGV[0]
puts "LVSDB_DUMP #{path}"
puts "RBA_LVS_CONSTANTS " + RBA.constants.select { |c| c.to_s =~ /Lvs/i }.inspect

begin
  r = RBA::LvsdbReader.new
  r.read(path)
  puts "CIRCUITS_BEGIN"
  r.each_circuit do |c|
    puts "CIRCUIT #{c.name}"
    begin
      c.each_net do |n|
        next unless n.respond_to?(:mismatch?) && n.mismatch?
        puts "  NET_MISMATCH #{n.name}"
      end
    rescue Exception => e
      puts "  NET_DUMP_ERROR #{e.class}: #{e.message}"
    end
    begin
      c.each_device do |d|
        next unless d.respond_to?(:mismatch?) && d.mismatch?
        puts "  DEVICE_MISMATCH #{d.name}"
      end
    rescue Exception => e
      puts "  DEVICE_DUMP_ERROR #{e.class}: #{e.message}"
    end
  end
  puts "CIRCUITS_END"
rescue Exception => e
  puts "LVSDB_READ_ERROR #{e.class}: #{e.message}"
end
